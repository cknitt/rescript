let implementMeLater = (): string => %todo("This should return a string eventually.")

let x = implementMeLater()

Console.log(x->Js.String2.includes("x"))
