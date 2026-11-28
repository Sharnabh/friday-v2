// Both desktop and mobile hosts supply an authenticated workspace transport.
async function mountGeminiLive(
  root,
  request,
  useDraft,
  captureState = () => {},
  options = {},
) {
  const node = (tag, label) => {
    const e = document.createElement(tag);
    e.textContent = label || "";
    return e;
  };
  const mode = node("select"),
    language = node("input"),
    start = node("button", "Start listening"),
    stop = node("button", "Stop");
  const status = node("p", "Choose a voice mode."),
    transcript = node("textarea"),
    paste = node("button", "Use transcript in chat");
  mode.setAttribute("aria-label", "Gemini Live mode");
  language.setAttribute("aria-label", "Target language code");
  language.value = "es";
  transcript.setAttribute("aria-label", "Live transcript");
  transcript.rows = 5;
  stop.disabled = true;
  root.classList.add("geminiLive");
  root.append(mode, language, start, stop, status, transcript, paste);
  let run = null,
    closed = false,
    saves = Promise.resolve();
  function interrupt(s) {
    for (const src of s.playing) {
      src.onended = null;
      src.stop();
    }
    s.playing.clear();
    s.next = 0;
  }
  function finish(message) {
    const s = run;
    run = null;
    if (s) {
      clearTimeout(s.timeout);
      s.mic?.getTracks().forEach((t) => t.stop());
      s.capture?.disconnect();
      interrupt(s);
      s.ctx?.close().catch(() => {});
      s.ws?.close();
      captureState(false);
    }
    start.disabled = false;
    stop.disabled = true;
    mode.disabled = false;
    language.disabled = false;
    status.textContent = message;
  }
  const visibility = () => {
    if (document.hidden && run) finish("Session stopped.");
  };
  document.addEventListener("visibilitychange", visibility);
  const cleanup = () => {
    closed = true;
    finish("Session closed.");
    document.removeEventListener("visibilitychange", visibility);
  };
  root.fridayAudioError=msg=>finish(msg);
  root.fridayClose = cleanup;
  root.fridayPause = () => {
    if (run?.ws) finish("Session stopped.");
  };
  stop.onclick = () => finish("Session stopped.");
  paste.onclick = () => {
    if (transcript.value.trim()) useDraft(transcript.value.trim());
  };
  mode.onchange = () => {
    try{localStorage.setItem("geminiLiveMode",mode.value)}catch{}
    language.hidden = !mode.value.includes("translate");
  };
  try {
    const catalog = await request("liveModels", {});
    for (const [label, id] of catalog.models) {
      const opt = node("option", label);
      opt.value = id;
      mode.append(opt);
    }
    try{const saved=localStorage.getItem("geminiLiveMode");if(catalog.models.some(row=>row[1]===saved))mode.value=saved}catch{}
    mode.onchange();
  } catch (e) {
    status.textContent = e.message;
    start.disabled = true;
  }
  start.onclick = async () => {
    if (run || closed) return;
    const model = mode.value,
      dictate = model.includes("transcribe"),
      translate = model.includes("translate");
    if (
      translate &&
      !/^[a-z]{2,3}(-[a-zA-Z]{2,4})?$/.test(language.value.trim())
    ) {
      status.textContent = "Enter a language code such as es or hi.";
      return;
    }
    const s = { playing: new Set(), next: 0, input: "", output: "" };
    run = s;

    const baseText = transcript.value.trimEnd();
    let completed = baseText ? baseText + "\n" : "";
    start.disabled = true;
    stop.disabled = false;
    mode.disabled = true;
    language.disabled = true;
    status.textContent = "Connecting…";
    try {
      s.ctx = new AudioContext();
      await s.ctx.resume();
      await captureState(true);
      if(run!==s)return;
      let mic=null;
      if(!options.nativeAudio) {
        try {mic=await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true}})}
        catch(error){if(error.name!=="NotReadableError")throw error;await new Promise(resolve=>setTimeout(resolve,350));if(run!==s)return;mic=await navigator.mediaDevices.getUserMedia({audio:true})}
      }
      if (run !== s) {
        mic?.getTracks().forEach((t) => t.stop());
        return;
      }
      s.mic = mic;
      const { token } = await request("liveToken", { model });
      if (run !== s) return;
      function connect(handle) {
        const ws = new WebSocket(
          "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained?access_token=" +
            encodeURIComponent(token),
        );
        s.ws = ws;
        ws.binaryType = "arraybuffer";
        s.timeout = setTimeout(() => {
          if (run === s) finish("Connection timed out. Start again.");
        }, 15000);
        ws.onopen = () => {
          if (run !== s) return;
          const generationConfig = {
            responseModalities: [dictate ? "TEXT" : "AUDIO"],
          };
          if (model.includes("extended-thinking"))
            generationConfig.thinkingConfig = { thinkingLevel: "HIGH" };
          if (translate) {
            generationConfig.translationConfig = {
              targetLanguageCode: language.value.trim(),
            };
            generationConfig.speechConfig = {
              languageCode: language.value.trim(),
            };
          }
          ws.send(
            JSON.stringify({
              setup: {
                model: "models/" + model,
                generationConfig,
                ...(!dictate && !translate
                  ? {
                      sessionResumption: handle ? { handle } : {},
                      tools: [
                        {
                          functionDeclarations: [
                            {
                              name: "list_open_tasks",
                              description:
                                "List the open tasks in this FRIDAY workspace.",
                              ...(model.includes("extended-thinking")
                                ? { behavior: "NON_BLOCKING" }
                                : {}),
                            },
                          ],
                        },
                      ],
                    }
                  : {}),
                inputAudioTranscription: {},
                ...(!dictate ? { outputAudioTranscription: {} } : {}),
              },
            }),
          );
        };
        ws.onmessage = (event) => {
          if (run !== s) return;
          try {
            const msg = JSON.parse(
              typeof event.data === "string"
                ? event.data
                : new TextDecoder().decode(event.data),
            );
            if (msg.sessionResumptionUpdate?.resumable)
              s.handle = msg.sessionResumptionUpdate.newHandle;
            if (msg.toolCall) {
              for (const call of msg.toolCall.functionCalls || []) {
                if (call.name !== "list_open_tasks") continue;
                request("liveTasks", {})
                  .then(({ tasks }) => {
                    if (ws.readyState === 1)
                      ws.send(
                        JSON.stringify({
                          toolResponse: {
                            functionResponses: [
                              {
                                id: call.id,
                                name: call.name,
                                response: { tasks },
                              },
                            ],
                          },
                        }),
                      );
                  })
                  .catch(() => {
                    if (ws.readyState === 1)
                      ws.send(
                        JSON.stringify({
                          toolResponse: {
                            functionResponses: [
                              {
                                id: call.id,
                                name: call.name,
                                response: { error: "Tasks unavailable" },
                              },
                            ],
                          },
                        }),
                      );
                  });
              }
            }
            if (msg.setupComplete) {
              clearTimeout(s.timeout);
              status.textContent = "Listening";
              if(options.initialText && !dictate && !translate && !handle){
                ws.send(JSON.stringify({clientContent:{turns:[{role:"user",parts:[{text:options.initialText}]}],turnComplete:true}}));
                s.input=options.initialText;options.initialText="";
              }
              if(options.nativeAudio){
                root.fridayPCM=data=>{if(run===s&&ws.readyState===1&&ws.bufferedAmount<131072)ws.send(JSON.stringify({realtimeInput:{audio:{mimeType:"audio/pcm;rate=16000",data}}}))};
                return;
              }
              const source = s.ctx.createMediaStreamSource(mic),
                capture = s.ctx.createScriptProcessor(2048, 1, 1);
              s.capture = capture;
              source.connect(capture);
              capture.connect(s.ctx.destination);
              capture.onaudioprocess = (e) => {
                if (ws.readyState !== 1 || ws.bufferedAmount > 131072) return;
                const samples = e.inputBuffer.getChannelData(0),
                  bytes = new Uint8Array(samples.length * 2),
                  view = new DataView(bytes.buffer);
                for (let i = 0; i < samples.length; i++)
                  view.setInt16(
                    2 * i,
                    Math.max(-1, Math.min(1, samples[i])) * 32767,
                    true,
                  );
                ws.send(
                  JSON.stringify({
                    realtimeInput: {
                      audio: {
                        mimeType: "audio/pcm;rate=" + s.ctx.sampleRate,
                        data: btoa(String.fromCharCode(...bytes)),
                      },
                    },
                  }),
                );
              };
            }
            const c = msg.serverContent;
            if (!c) return;
            if (c.interrupted) interrupt(s);
            for (const part of c.modelTurn?.parts || []) {
              const data = part.inlineData;
              if (!data?.mimeType?.startsWith("audio/pcm")) continue;
              const raw = atob(data.data),
                rate = Number(/rate=(\d+)/.exec(data.mimeType)?.[1] || 24000);
              const buf = s.ctx.createBuffer(1, raw.length >> 1, rate),
                out = buf.getChannelData(0);
              for (let i = 0; i < out.length; i++) {
                const n =
                  raw.charCodeAt(2 * i) | (raw.charCodeAt(2 * i + 1) << 8);
                out[i] = ((n << 16) >> 16) / 32768;
              }
              const src = s.ctx.createBufferSource();
              src.buffer = buf;
              src.connect(s.ctx.destination);
              s.playing.add(src);
              src.onended = () => s.playing.delete(src);
              s.next = Math.max(s.ctx.currentTime, s.next);
              src.start(s.next);
              s.next += buf.duration;
            }
            const input = c.inputTranscription?.text || "",
              output = c.outputTranscription?.text || "";
            s.input += input;
            s.output += output;
            transcript.value =
              completed + s.input + (s.output ? "\nGemini: " + s.output : "");
            if (c.turnComplete) {
              completed = transcript.value.trimEnd() + "\n";
              transcript.value = completed;
              if (!dictate && (s.input || s.output)) {
                const turn = {
                  id: crypto.randomUUID(),
                  input: s.input,
                  output: s.output,
                };
                saves = saves
                  .then(() => request("liveTurn", turn))
                  .catch((e) => {
                    status.textContent = "Transcript sync failed: " + e.message;
                  });
              }
              s.input = "";
              s.output = "";
            }
          } catch {
            finish("Could not process the Live response.");
          }
        };
        ws.onerror = () => {
          if (run === s) status.textContent = "Connection interrupted.";
        };
        ws.onclose = (e) => {
          if (run !== s) return;
          if ([1006, 1012, 1013].includes(e.code) && s.handle && !s.retried) {
            s.retried = true;
            s.capture?.disconnect();
            if (s.capture) s.capture.onaudioprocess = null;
            interrupt(s);
            status.textContent = "Reconnecting…";
            connect(s.handle);
            return;
          }
          finish("Session ended (" + e.code + "). Start again to reconnect.");
        };
      }
      connect(null);
    } catch (e) {
      if (run === s)
        finish(e.message || "Microphone or Live session unavailable.");
    }
  };
  if(options.autoStart && !closed && !start.disabled) await start.onclick();
}
