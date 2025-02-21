let lazy1 = Lazy.from_fun(() => {
  "Hello, lazy"->Console.log
  1
})

let lazy2 = Lazy.from_fun(() => 3)

Console.log2(lazy1, lazy2)

// can't destructure lazy values
let (la, lb) = (Lazy.force(lazy1), Lazy.force(lazy2))

Console.log2(la, lb)
