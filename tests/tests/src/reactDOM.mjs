// Generated by ReScript, PLEASE EDIT WITH CARE

import * as Primitive_option from "rescript/lib/es6/Primitive_option.js";

let Root = {};

let Client = {
  Root: Root
};

function getString(formData, name) {
  let value = formData.get(name);
  if (!(value == null) && typeof value === "string") {
    return Primitive_option.some(value);
  }
  
}

function getFile(formData, name) {
  let value = formData.get(name);
  if (!(value == null) && typeof value !== "string") {
    return Primitive_option.some(value);
  }
  
}

function getAll(t, string) {
  return t.getAll(string).map(value => {
    if (typeof value === "string") {
      return {
        TAG: "String",
        _0: value
      };
    } else {
      return {
        TAG: "File",
        _0: value
      };
    }
  });
}

let FormData = {
  getString: getString,
  getFile: getFile,
  getAll: getAll
};

let Ref = {};

let Style;

export {
  Client,
  FormData,
  Ref,
  Style,
}
/* No side effect */
