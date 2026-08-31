val decode_js_escapes : string -> string option
(** Decode the escape sequences in a JavaScript string-literal body into its
    semantic UTF-8 value. Returns [None] for malformed input or unpaired
    UTF-16 surrogates. *)

val utf16_length : string -> int
(** Return the number of UTF-16 code units in a semantic UTF-8 string, matching
    JavaScript's [String.length]. *)

val code_point_at_utf16_index : string -> int -> int option
(** Return the result of JavaScript's [String.codePointAt] for a UTF-16 code
    unit index into a semantic UTF-8 string. *)
