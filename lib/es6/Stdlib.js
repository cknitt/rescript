

import * as Stdlib_Global from "./Stdlib_Global.js";
import * as Stdlib_JsError from "./Stdlib_JsError.js";
import * as Primitive_object from "./Primitive_object.js";

function assertEqual(a, b) {
  if (!Primitive_object.notequal(a, b)) {
    return;
  }
  throw {
    RE_EXN_ID: "Assert_failure",
    _1: [
      "Stdlib.res",
      122,
      4
    ],
    Error: new Error()
  };
}

let TimeoutId = Stdlib_Global.TimeoutId;

let IntervalId = Stdlib_Global.IntervalId;

let $$Array;

let $$BigInt;

let Bool;

let Console;

let $$DataView;

let $$Date;

let Dict;

let Exn;

let $$Error;

let Float;

let Int;

let $$Intl;

let JsError;

let JsExn;

let $$JSON;

let Lazy;

let List;

let $$Math;

let Null;

let Nullable;

let $$Object;

let Option;

let Ordering;

let Pair;

let $$Promise;

let $$RegExp;

let Result;

let $$String;

let $$Symbol;

let Type;

let $$Iterator;

let $$AsyncIterator;

let $$Map;

let $$WeakMap;

let $$Set;

let $$WeakSet;

let $$ArrayBuffer;

let $$TypedArray;

let $$Float32Array;

let $$Float64Array;

let $$Int8Array;

let $$Int16Array;

let $$Int32Array;

let $$Uint8Array;

let $$Uint16Array;

let $$Uint32Array;

let $$Uint8ClampedArray;

let $$BigInt64Array;

let $$BigUint64Array;

let panic = Stdlib_JsError.panic;

export {
  TimeoutId,
  IntervalId,
  $$Array,
  $$BigInt,
  Bool,
  Console,
  $$DataView,
  $$Date,
  Dict,
  Exn,
  $$Error,
  Float,
  Int,
  $$Intl,
  JsError,
  JsExn,
  $$JSON,
  Lazy,
  List,
  $$Math,
  Null,
  Nullable,
  $$Object,
  Option,
  Ordering,
  Pair,
  $$Promise,
  $$RegExp,
  Result,
  $$String,
  $$Symbol,
  Type,
  $$Iterator,
  $$AsyncIterator,
  $$Map,
  $$WeakMap,
  $$Set,
  $$WeakSet,
  $$ArrayBuffer,
  $$TypedArray,
  $$Float32Array,
  $$Float64Array,
  $$Int8Array,
  $$Int16Array,
  $$Int32Array,
  $$Uint8Array,
  $$Uint16Array,
  $$Uint32Array,
  $$Uint8ClampedArray,
  $$BigInt64Array,
  $$BigUint64Array,
  panic,
  assertEqual,
}
/* No side effect */
