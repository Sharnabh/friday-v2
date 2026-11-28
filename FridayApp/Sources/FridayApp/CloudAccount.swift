import SwiftUI
import CryptoKit
import FridayCore

@MainActor
final class CloudAccount: ObservableObject {
    static let service = "local.friday.assistant.cloud.session"
    @Published var token = SpeechCredential.read(service: service) ?? ""
    @Published var signing = false
    @Published var status = ""
    @Published var snapshot: [String:Any] = [:]
    @Published var name = UserDefaults.standard.string(forKey:"cloudAccountName") ?? ""
    private var loop: Task<Void,Never>?
    private var desktopRequest: (id:String,key:String)?
    private var revision = -1
    private var lastHeavySync = Date.distantPast
    private var checkpoints: [String:String] = [:]
    private let endpoint = "https://friday-workspace.friday-workspace.workers.dev/v1/"

    func start(_ state: AppState) {
        guard loop == nil else { return }
        checkpoints = UserDefaults.standard.dictionary(forKey:"cloudCheckpoint."+name) as? [String:String] ?? [:]
        loop = Task { [weak self,weak state] in
            while !Task.isCancelled {
                if let self, let state, !token.isEmpty {
                    do { try await refresh(state) } catch { status = error.localizedDescription }
                }
                try? await Task.sleep(for:.seconds(6))
            }
        }
    }

    private func post(_ path: String, _ body: [String:Any]) async throws -> [String:Any] {
        let used = token
        var req = URLRequest(url:URL(string:endpoint+path)!)
        req.httpMethod = "POST"
        req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if !used.isEmpty {req.setValue("Bearer "+used,forHTTPHeaderField:"Authorization")}
        req.httpBody = try JSONSerialization.data(withJSONObject:body)
        let (data,res) = try await URLSession.shared.data(for:req)
        guard used == token else { throw CancellationError() }
        let obj = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
        guard (res as? HTTPURLResponse)?.statusCode == 200, obj["error"] == nil else {
            throw FridayError.message(obj["error"] as? String ?? "Cloud workspace unavailable.")
        }
        return obj
    }

    func sign(_ user:String,_ password:String,create:Bool,state:AppState) async {
        guard !signing else {return}
        let user=user.trimmingCharacters(in:.whitespacesAndNewlines)
        guard user.range(of:"^[a-zA-Z0-9_.-]{3,64}$",options:.regularExpression) != nil else {status="Use a username with 3–64 letters, digits, dots, dashes or underscores.";return}
        guard (12...256).contains(password.count) else {status="Enter a password of 12–256 characters.";return}
        signing=true;status=create ? "Creating account…" : "Signing in…"
        defer {signing=false}
        do {
            let response = try await post(create ? "signup":"login",["username":user,"password":password])
            guard let session = response["token"] as? String else { throw FridayError.message("Missing session") }
            do {try SpeechCredential.save(session,service:Self.service);status="Signed in."}
            catch {status="Signed in for this session. Keychain could not save the login."}
            revision = -1; lastHeavySync = .distantPast
            token = session
            name = user.lowercased()
            UserDefaults.standard.set(name,forKey:"cloudAccountName")
            if UserDefaults.standard.string(forKey:"cloudMacProfileOwner")==nil {
                UserDefaults.standard.set(name,forKey:"cloudMacProfileOwner")
            }
            checkpoints = UserDefaults.standard.dictionary(forKey:"cloudCheckpoint."+name) as? [String:String] ?? [:]
            start(state)
        } catch {status = error.localizedDescription}
    }

    func signOut() async {
        do {
            _ = try? await post("logout",[:])
            try SpeechCredential.save("",service:Self.service)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains("transcript.cloud-account-") {
                UserDefaults.standard.removeObject(forKey:key)
            }
            desktopRequest = nil
            token = ""; snapshot = [:]; status = ""; checkpoints = [:]
            UserDefaults.standard.set(false,forKey:"cloudMacTools")
        } catch {status=error.localizedDescription}
    }

    func action(_ action:String,_ fields:[String:Any] = [:]) async {
        var req = fields
        req["action"] = action
        req["session"] = snapshot["session"]; req["bot"] = snapshot["bot"]
        do { snapshot = try await post("workspace",req) } catch {status = error.localizedDescription}
    }

    func liveRequest(_ action:String,_ data:[String:Any],_ target:[String:String]) async throws -> [String:Any] {
        var req=data
        for (key,value) in target {req[key]=value}
        req["action"]=action
        return try await post("workspace",req)
    }

    private func hash(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }

    private func upload(_ key:String,_ fields:[String:Any]) async throws {
        let digest = hash(try JSONSerialization.data(withJSONObject:fields,options:.sortedKeys))
        guard checkpoints[key] != digest else {return}
        var req=fields; req["action"]="import"
        _ = try await post("workspace",req)
        checkpoints[key]=digest
        UserDefaults.standard.set(checkpoints,forKey:"cloudCheckpoint."+name)
    }

    private func collection(_ kind:String, _ rows:[[String:Any]], keys:[String]) async throws {
        let defaults=UserDefaults.standard
        let storage="cloudRows."+name+"."+kind
        let previous=defaults.dictionary(forKey:storage) as? [String:[String:String]] ?? [:]
        var next=[String:[String:String]](), changed=[[String:Any]]()
        for row in rows {
            let fields=Dictionary(uniqueKeysWithValues:keys.map{($0,row[$0] as? String ?? "")})
            let uid=hash(try JSONSerialization.data(withJSONObject:fields,options:.sortedKeys))
            let digest=hash(try JSONSerialization.data(withJSONObject:row,options:.sortedKeys))
            next[uid]=fields.merging(["digest":digest]){$1}
            if previous[uid]?["digest"] != digest { changed.append(row) }
        }
        let removed=previous.compactMap { key,value -> [String:String]? in
            next[key] == nil ? value.merging(["kind":kind]){$1} : nil
        }
        if !changed.isEmpty || !removed.isEmpty {
            _ = try await post("workspace",["action":"import",kind:changed,"removed":removed])
            defaults.set(next,forKey:storage)
        }
    }

    private func refresh(_ state:AppState) async throws {
        snapshot = try await post("workspace",["action":"state"])
        if let owner=UserDefaults.standard.string(forKey:"cloudMacProfileOwner"),owner != name {
            status="This account uses its cloud workspace. Local Mac data syncs with "+owner+"."
            return
        }
        if let command=desktopRequest, !state.isBusy {
            let result=UserDefaults.standard.stringArray(forKey:command.key)?.last ?? state.statusMessage
            _ = try await post("workspace",["action":"macResult","id":command.id,"text":result.hasPrefix("You\n") ? state.statusMessage : result])
            desktopRequest=nil
        }
        if UserDefaults.standard.bool(forKey:"cloudMacTools"), !state.isBusy, state.inputMessage.isEmpty {
            let command = try await post("workspace",["action":"macPoll"])
            if let text = command["request"] as? String, !text.isEmpty {
                if let tool=command["tool"] as? String,!tool.isEmpty {
                    let owner=command["bot"] as? String ?? ""
                    let guest=state.guestForOwner(owner)
                    var response=""
                    switch tool {
                    case "guestStart": await guest.start(owner:owner,installer:nil);response=guest.message
                    case "guestStop": guest.shutdown();response=guest.message
                    case "guestFile":
                        if let dir=guest.exchange {
                            let url=dir.appendingPathComponent("Handoff-"+UUID().uuidString+".txt")
                            try text.write(to:url,atomically:true,encoding:.utf8);response="Saved "+url.lastPathComponent
                        } else {response="Start the guest on your Mac to open its shared folder."}
                    default: response=guest.guest == nil ? "Guest is stopped." : "Guest is running."
                    }
                    _ = try await post("workspace",["action":"macResult","id":command["id"] ?? "","text":response])
                    return
                }
                if state.currentSessionId.hasPrefix("cloud-account-") {state.newChat()}
                desktopRequest=(command["id"] as? String ?? "",state.activeBotScope+"transcript."+state.sessionID)
                state.inputMessage=text; state.sendMessage()
            }
        }
        guard !state.isBusy, snapshot["busy"] as? Bool != true else {return}
        if Date().timeIntervalSince(lastHeavySync) < 20 {
            try await download(state); return
        }
        let defaults=UserDefaults.standard
        try await syncPreferences(state)
        let profiles = ([BotProfile(id:"",name:state.fridayName,instructions:state.fridayInstructions,voice:state.fridayVoice,role:state.fridayRole)] + state.bots)
        let profilesJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(profiles.sorted{$0.id<$1.id}))
        let groupsJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(state.groups.sorted{$0.id<$1.id}))
        try await upload("profiles",["bots":profilesJSON,"groups":groupsJSON,"keepProfiles":false])
        for (key,value) in defaults.dictionaryRepresentation() {
            guard !key.contains("transcript.cloud-account-"), let turns=value as? [String], !turns.isEmpty else {continue}
            let bot:String
            if key.hasPrefix("transcript.") {bot=""}
            else if key.hasPrefix("bot."), let range=key.range(of:".transcript.") { bot=String(key[key.index(key.startIndex,offsetBy:4)..<range.lowerBound]) }
            else {continue}
            let offsets=Set(defaults.array(forKey:"cloudOffsets."+name+"."+key) as? [Int] ?? [])
            let messages = turns.enumerated().filter{!offsets.contains($0.offset)}.map { _,turn -> [String:String] in
                let parts=turn.split(separator:"\n",maxSplits:1,omittingEmptySubsequences:false)
                let speaker=String(parts[0])
                return ["speaker":speaker,"role":speaker=="You" ? "user":"assistant","text":parts.count>1 ? String(parts[1]):turn]
            }
            try await upload(key,["chats":[["id":"mac-"+hash(Data(key.utf8)),"bot":bot,"title":String((messages.first?["text"] ?? "Chat").prefix(60)),"messages":messages]]])
        }
        if let store=state.memoryStore {
            let memories=try store.search("",scope:"all",limit:10000).map { ["scope":$0.scope,"body":$0.body,"source":$0.source,"importance":$0.importance] as [String:Any] }
            let triples=try store.listTriples(scope:"all",limit:10000)
            try await collection("memories",memories,keys:["scope","body"])
            let graph=triples.map{["scope":$0.scope,"subject":$0.subject,"predicate":$0.predicate,"object":$0.object,"confidence":$0.confidence] as [String:Any]}
            try await collection("triples",graph,keys:["scope","subject","predicate"])
        }
        let tasks=state.reminders.map { ["id":$0.id.uuidString.lowercased(),"title":$0.text,"due":ISO8601DateFormatter().string(from:$0.due)] }
        try await collection("tasks",tasks,keys:["id"])
        lastHeavySync = Date()
        try await download(state)
        status="Synced"
    }

    private func syncPreferences(_ state:AppState) async throws {
        let defaults=UserDefaults.standard
        let key="cloudPreferences."+name
        let last=defaults.dictionary(forKey:key) ?? [:]
        let registry=OpenRouterModelRegistry.shared
        let roles=Dictionary(uniqueKeysWithValues:ModelRole.allCases.map{($0.rawValue,registry.preferredModel(for:$0) ?? "")})
        let local:[String:Any]=["model":defaults.string(forKey:"chatModel") ?? "", "embedding":state.memoryEmbeddingMode.rawValue,
                               "decider":state.isDeciderRoutingEnabled,"rerank":state.isCloudRerankEnabled,"roles":roles]
        var changes=[String:Any]()
        for (field,value) in local {
            if let prev=last[field] as? NSObject, !prev.isEqual(value) {changes[field]=value}
        }
        let remote=try await post("workspace",["action":"syncPreferences","changes":changes,"seed":last.isEmpty ? local : [:]])
        if let model=remote["model"] as? String {
            let value=model=="openrouter/free" ? "" : model
            if state.activeBotId.isEmpty {state.model=value}
            else {defaults.set(value,forKey:"chatModel")}
        }
        if let mode=MemoryEmbeddingMode(rawValue:remote["embedding"] as? String ?? ""){state.memoryEmbeddingMode=mode}
        state.isDeciderRoutingEnabled=remote["decider"] as? Bool ?? false
        state.isCloudRerankEnabled=remote["rerank"] as? Bool ?? false
        var mapped=[String:String]()
        for role in ModelRole.allCases {
            let value=(remote["roles"] as? [String:String])?[role.rawValue] ?? ""
            mapped[role.rawValue]=value
            if roles[role.rawValue] != value {registry.setPreferredModel(value,for:role)}
        }
        var baseline=remote
        baseline["roles"]=mapped;baseline["model"]=defaults.string(forKey:"chatModel") ?? ""
        defaults.set(baseline,forKey:key)
    }

    func sendFromMirror(_ text:String, id:String, state:AppState) async {
        defer { state.isBusy=false }
        do {
            var view = try await post("workspace",["action":"state"])
            if view["session"] as? String != id {
                view = try await post("workspace",["action":"selectSession","id":id,"bot":view["bot"] ?? "","session":view["session"] ?? ""])
            }
            snapshot = try await post("workspace",["action":"send","text":text,"bot":view["bot"] ?? "","session":id])
            if state.inputMessage == text {state.inputMessage=""}
            state.statusMessage="Sent to FRIDAY"
        } catch {state.statusMessage=error.localizedDescription}
    }

    private func download(_ state:AppState) async throws {
        let data = try await post("workspace",["action":"syncRead","revision":revision])
        guard let chats=data["chats"] as? [[String:Any]], !state.isBusy else {return}
        let defaults=UserDefaults.standard
        var keys=Set<String>()
        let localKeys=defaults.dictionaryRepresentation().keys.filter{
            !$0.contains("transcript.cloud-account-") && ($0.hasPrefix("transcript.") || ($0.hasPrefix("bot.") && $0.contains(".transcript.")))
        }
        let originals=Dictionary(uniqueKeysWithValues:localKeys.map{("mac-"+hash(Data($0.utf8)),$0)})
        var pendingLocal=false
        for chat in chats {
            guard let id=chat["id"] as? String, let bot=chat["bot"] as? String, let turns=chat["turns"] as? [String] else {continue}
            if let original=originals[id] {
                let offsetKey="cloudOffsets."+name+"."+original
                let oldOffsets=Set(defaults.array(forKey:offsetKey) as? [Int] ?? [])
                let newOffsets=Set(chat["cloudOffsets"] as? [Int] ?? [])
                let local=defaults.stringArray(forKey:original) ?? []
                let localSource=local.enumerated().filter{!oldOffsets.contains($0.offset)}.map(\.element)
                let remoteSource=turns.enumerated().filter{!newOffsets.contains($0.offset)}.map(\.element)
                guard localSource == remoteSource else {pendingLocal=true;continue}
                if local != turns {defaults.set(turns,forKey:original)}
                defaults.set(newOffsets.sorted(),forKey:offsetKey)
                continue
            }
            let key=(bot.isEmpty ? "" : "bot."+bot+".")+"transcript.cloud-account-"+id
            keys.insert(key)
            if defaults.stringArray(forKey:key) != turns {defaults.set(turns,forKey:key)}
        }
        for key in defaults.dictionaryRepresentation().keys where key.contains("transcript.cloud-account-") && !keys.contains(key) {
            defaults.removeObject(forKey:key)
        }
        if let bots=data["bots"] as? [[String:Any]], let groups=data["groups"] as? [[String:Any]] {
            var local=defaults.dictionary(forKey:"fridayBots") as? [String:[String:String]] ?? [:]
            for bot in bots {
                guard let id=bot["id"] as? String, !id.isEmpty else {continue}
                local[id]=["name":bot["name"] as? String ?? "Assistant","role":bot["role"] as? String ?? "auto","voice":bot["voice"] as? String ?? "","instructions":bot["instructions"] as? String ?? ""]
            }
            defaults.set(local,forKey:"fridayBots")
            var groupMap=Dictionary(uniqueKeysWithValues:state.groups.map{($0.id,$0)})
            for group in groups {
                if let id=group["id"] as? String, let members=group["members"] as? [String], let title=group["name"] as? String {
                    groupMap[id]=BotGroup(id:id,name:title,members:members)
                }
            }
            defaults.set(try JSONEncoder().encode(groupMap),forKey:"namedGroups")
            state.loadBotsAndGroups()
        }
        if let store=state.memoryStore {
            let facts=data["memories"] as? [[String:Any]] ?? []
            let visible=Set(facts.map{[$0["scope"] as? String ?? "",$0["body"] as? String ?? ""]})
            let previous=defaults.dictionary(forKey:"cloudRows."+name+".memories") as? [String:[String:String]] ?? [:]
            for entry in previous.values {
                guard let scope=entry["scope"],let body=entry["body"],!visible.contains([scope,body]) else {continue}
                if let id=try store.latestMemoryRowID(scope:scope,body:body){try store.remove(id:id)}
            }
            let graph=data["triples"] as? [[String:Any]] ?? []
            let relations=Set(graph.map{[$0["scope"] as? String ?? "",$0["subject"] as? String ?? "",$0["predicate"] as? String ?? ""]})
            let old=defaults.dictionary(forKey:"cloudRows."+name+".triples") as? [String:[String:String]] ?? [:]
            let previousRelations=Set(old.values.map{[$0["scope"] ?? "",$0["subject"] ?? "",$0["predicate"] ?? ""]})
            for item in try store.listTriples(scope:"all",limit:10000) {
                let identity=[item.scope,item.subject,item.predicate]
                if previousRelations.contains(identity) && !relations.contains(identity){try store.deleteTriple(id:item.id)}
            }
            for row in data["memories"] as? [[String:Any]] ?? [] {
                guard let scope=row["scope"] as? String, let body=row["body"] as? String else {continue}
                if try store.latestMemoryRowID(scope:scope,body:body)==nil {
                    try store.save(body,scope:scope,source:row["source"] as? String ?? "FRIDAY",importance:row["importance"] as? Int ?? 5,original:nil)
                }
            }
            for row in data["triples"] as? [[String:Any]] ?? [] {
                if let scope=row["scope"] as? String, let sub=row["subject"] as? String, let pred=row["predicate"] as? String,let obj=row["object"] as? String {
                    try store.saveTriple(GraphTriple(scope:scope,subject:sub,predicate:pred,object:obj,confidence:row["confidence"] as? Double ?? 1))
                }
            }
            state.loadMemories()
        }
        if let tasks=data["tasks"] as? [[String:Any]] {
            try state.reminderService.update { reminders in
                for task in tasks {
                    guard let raw=task["id"] as? String,let id=UUID(uuidString:raw) else{continue}
                    if task["done"] as? Int==1 {reminders.removeAll{$0.id==id};continue}
                    guard let due=ISO8601DateFormatter().date(from:task["due"] as? String ?? ""), due>Date(),
                          let title=task["title"] as? String, !reminders.contains(where:{$0.id==id}) else{continue}
                    reminders.append(Reminder(id:id,text:title,due:due,frequency:nil))
                }
            }
            state.loadReminders()
        }
        state.loadTranscripts();state.loadSessions()
        revision=pendingLocal ? -1 : (data["revision"] as? Int ?? -1)
    }
}

struct LiveEntryView: View {
    @ObservedObject var account:CloudAccount
    let state:AppState
    let autoStart:Bool
    var body:some View {
        if account.token.isEmpty {CloudAccountView(account:account,state:state)}
        else {GeminiLiveView(account:account,autoStart:autoStart){ text in
            state.inputMessage += (state.inputMessage.isEmpty ? "" : "\n") + text
            state.liveWakePresented=false
        }}
    }
}

struct CloudAccountView: View {
    @ObservedObject var account:CloudAccount
    let state:AppState
    @State private var user=""
    @State private var password=""
    @State private var message=""
    @AppStorage("cloudMacTools") private var allowTools=false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if account.token.isEmpty {
                Text("Gemini Live").font(.headline)
                Text("Sign in to sync this Mac’s chats, assistants and memories with your FRIDAY account.")
                TextField("Username",text:$user)
                SecureField("Password",text:$password)
                if !account.status.isEmpty {Text(account.status).textSelection(.enabled)}
                HStack {
                    Button("Sign in"){Task{await account.sign(user,password,create:false,state:state);if !account.token.isEmpty {password=""}}}
                    Button("Create account"){Task{await account.sign(user,password,create:true,state:state);if !account.token.isEmpty {password=""}}}
                }.disabled(account.signing)
            } else {
                HStack {Text(account.name).font(.headline);Spacer();Button("Sign out"){Task{await account.signOut()}}}
                Button("Gemini Live"){state.presentLive()}
                Toggle("Allow requests from my phone to use Mac tools",isOn:$allowTools)
                HStack {
                    Menu("Cloud chats"){
                        ForEach(account.snapshot["sessions"] as? [[String:String]] ?? [],id:\.self){ row in
                            Button(row["name"] ?? "Chat"){Task{await account.action("selectSession",["id":row["id"] ?? ""])}}
                        }
                    }
                    Button("New chat"){Task{await account.action("new")}}
                }
                Text((account.snapshot["turns"] as? [String] ?? []).joined(separator:"\n\n")).textSelection(.enabled)
                HStack {TextField("Message FRIDAY",text:$message);Button("Send"){let text=message;Task{await account.action("send",["text":text]);message=""}}}
            }
            if !account.token.isEmpty {Text(account.status).font(.caption)}
        }.padding()
    }
}
