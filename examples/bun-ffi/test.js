import { dlopen } from "bun:ffi";

// Adjust the dylib/so name per platform if needed
const libPath = {
  darwin: "./zig-out/lib/libzigquicheh3.dylib",
  linux: "./zig-out/lib/libzigquicheh3.so",
  win32: "./zig-out/bin/zigquicheh3.dll",
}[process.platform] || "./zig-out/lib/libzigquicheh3.dylib";

const lib = dlopen(libPath, {
  zig_h3_version: {
    returns: "cstring",
    args: [],
  },
});

console.log("Quiche version from Bun:", lib.symbols.zig_h3_version());

