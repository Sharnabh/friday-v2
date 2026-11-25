// Invoked by osascript. Mail manages reply threading, addressing and final Send.
function run(args) {
    try {
        const mail = Application("Mail");
        const selection = mail.selection();
        if (selection.length !== 1) throw Error("Select one message in Apple Mail, then try again.");
        const message = selection[0];
        const identity = JSON.stringify([message.id(), message.messageId(), message.sender()]);
        if (args[0] === "read") {
            return JSON.stringify({identity, subject: message.subject(), sender: message.sender(),
                body: String(message.content()).slice(0, 12000)});
        }
        if (args[0] !== "draft" || identity !== args[1]) throw Error("The selected message changed. Select the intended email and try again.");
        const draft = mail.reply(message, {openingWindow: false, replyToAll: false});
        draft.content = args[2] + "\n\n" + String(draft.content());
        draft.visible = true;
        mail.activate();
        return JSON.stringify({recipients: draft.toRecipients().map(recipient => recipient.address()).join(", ")});
    } catch (error) {
        return JSON.stringify({error: String(error.message || error)});
    }
}
