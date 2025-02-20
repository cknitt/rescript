type rec eq = Mt.eq =
  | Eq('a, 'a): eq
  | Neq('a, 'a): eq
  | StrictEq('a, 'a): eq
  | StrictNeq('a, 'a): eq
  | Ok(bool): eq
  | Approx(float, float): eq
  | ApproxThreshold(float, float, float): eq
  | ThrowAny(unit => unit): eq
  | Fail(unit): eq
  | FailWith(string): eq
type pair_suites = list<(string, unit => eq)>

let from_pair_suites = (name: string, suites: pair_suites) => {
  Console.log((name, "testing"))
  suites->Belt.List.forEach(((name, code)) =>
    switch code() {
    | Eq(a, b) => Console.log((name, a, "eq?", b))
    | Neq(a, b) => Console.log((name, a, "neq?", b))
    | StrictEq(a, b) => Console.log((name, a, "strict_eq?", b))
    | StrictNeq(a, b) => Console.log((name, a, "strict_neq?", b))
    | Approx(a, b) => Console.log((name, a, "~", b))
    | ApproxThreshold(t, a, b) => Console.log((name, a, "~", b, " (", t, ")"))
    | ThrowAny(fn) => ()
    | Fail(_) => Console.log("failed")
    | FailWith(msg) => Console.log("failed: " ++ msg)
    | Ok(a) => Console.log((name, a, "ok?"))
    }
  )
}
