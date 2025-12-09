type inbound =
  | Transcript(string)
  | AssistantTextDelta(string)
  | AssistantTextDone
  | AudioChunk(string)
  | ErrorEvent(string)
  | SessionClosed
  | Unknown(string)

let decode = (~data: string): array<inbound> =>
  switch JSON.parseOrThrow(data) {
  | JSON.Object(dict{"delta": JSON.String(d)}) => [AssistantTextDelta(d)]
  | JSON.Object(dict{"transcript": JSON.String(t)}) => [
      AssistantTextDone,
      AssistantTextDelta(t),
    ]
  | JSON.Object(dict{"type": JSON.String("response.output_text.done")}) => [
      AssistantTextDone,
    ]
  | JSON.Object(dict{"type": JSON.String("response.audio.done")}) => []
  | JSON.Object(dict{"type": JSON.String("session.updated")}) => []
  | JSON.Object(dict{
      "type": JSON.String("error"),
      "error": JSON.Object(err),
    }) =>
    let msg = switch Dict.get(err, "message") {
    | Some(JSON.String(m)) => m
    | _ => "realtime error"
    }
    if String.includes(msg, "no active response found") {
      []
    } else {
      [ErrorEvent(msg)]
    }
  | JSON.Object(dict{"type": JSON.String("realtime_closed")}) => [SessionClosed]
  }
