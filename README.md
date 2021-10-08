# hwzip.zig

## What's hwzip.zig?

It's a port in Zig of the program **hwzip-2.0** written by Hans Wennborg.
- [Zip Files: History, Explanation and Implementation](https://www.hanshq.net/zip.html)
- [Shrink, Reduce, and Implode: The Legacy Zip Compression Methods](https://www.hanshq.net/zip2.html)

**hwzip** is an example implementation written in C of the Zip file format.

**hwzip.zig** is a Zig version in an attempt to make it more accessible.

I tried to make the least amount of changes possible so that one can still follow the article with the Zig code instead of C.
This means it's not idiomatic Zig code, it's more a translation than a port.

## Why hwzip.zig?

 - Because you can compile, test and run it without any dependencies (except Zig).
   The C version requires the usual hell of building utilities, the *Info-ZIP* binary and links into *zlib*.

 - I needed a way to compress files in Zig.

 - I wanted to learn about Zip files and Zig is much more readable to me than C.

## Building instructions

Download and install [Zig](https://ziglang.org/download/) **0.9.0**

To build the binary in `./zig-out/bin/hwzip` you need to run

```bash
zig build
```

## Testing instructions

```bash
zig build test
```

## Usage

Executing without any arguments print the help message

```bash
./hwzip list <zipfile>
./hwzip extract <zipfile>
./hwzip create <zipfile> [-m <method>] [-c <comment>] <files...>

Supported compression methods: 
store, shrink, reduce, implode, deflate (default).
```

## List of changes from *hwzip-2.0*

 - The debug field `huffman_decoder_t.num_syms` is commented out.
 - Fuzz tests are missing.
 - Uses `std.hash.crc32()` from Zig instead of a custom one.
 - Uses epoch dos date for dates before 1980-01-01 in `zip.ctime2dos()`
 - The table `reverse8_tbl` is replaced by the function `bits.reverse8()`.
 - Fixed some typos `CHECK(x = y)` instead of `CHECK(x == y)` in some tests.
 - Fixed an integer overflow causing the compression percentage being wrong for compressed files bigger than 42,949,673 bytes `(hwzip.c:202) (100*comp_size)`.

## Limitations

**hwzip.zig** comes with no warranties, I may have introduced bugs which are not in the original version *hwzip-2.0*.

You cannot recursively compress files within a directory, you need to list all files that you want to add to the archive.

This utility is slow and is not meant for daily use, you should use more serious tools like Info-ZIP, 7zip or gzip to compress your files.

## License

The `./doc` directory contains a copy of the articles explaining the Zip file format which are under [Hans Wennborg](https://www.hanshq.net/) copyright.

`time.zig` is a port of some portion of `src/time` from *musl libc* and as such this file is under the standard MIT license, see the `LICENSE-time-dot-zig` file.

The rest is public domain unless specified otherwise, see the `LICENSE` file.
