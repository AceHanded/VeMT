# VeMT

[![CI](https://img.shields.io/github/actions/workflow/status/AceHanded/VeMT/ci.yml?style=for-the-badge)](https://github.com/AceHanded/VeMT/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/AceHanded/VeMT?style=for-the-badge)](https://github.com/AceHanded/VeMT/blob/main/LICENSE)
[![ZigVersion](https://img.shields.io/badge/zig-0.17.1-yellow?style=for-the-badge&logo=zig)](https://ziglang.org/)
[![GitHubStars](https://img.shields.io/github/stars/AceHanded/VeMT?style=for-the-badge&logo=github&labelColor=black)](https://github.com/AceHanded/VeMT)
[![BuyMeACoffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ffdd00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/acehand)

An easy-to-use CLI text translation tool for installing and running machine translation models from [OPUS-MT](https://github.com/Helsinki-NLP/Opus-MT) using [CTranslate2](https://github.com/OpenNMT/CTranslate2) for inference and [SentencePiece](https://github.com/google/sentencepiece) for tokenization.

## Installation

### Precompiled binaries

If you are using Windows, you can download the precompiled binary from the [Releases](https://github.com/AceHanded/VeMT/releases) section. On other systems, you will have to build the program from source.

### Building from source

#### Prerequisites

- [Zig](https://ziglang.org/)
- [CMake](https://cmake.org/)
- [CTranslate2](https://github.com/OpenNMT/CTranslate2)
- ([Python 3.9+](https://www.python.org/))

#### Instructions

> [!NOTE]
> The following instruction describe the build process on Windows. On other systems, you will likely have to modify the build components and commands.

First, clone the repository:

```ps1
git clone https://github.com/AceHanded/VeMT.git
cd VeMT
```

Next, build the C++ wrapper with CMake. Ensure that CTranslate2 is installed and that its installation path is available through `CMAKE_PREFIX_PATH` or `ctranslate2_DIR`. [OpenBLAS](https://github.com/OpenMathLib/OpenBLAS) is used as its backend in the distributed release.

```ps1
cd cpp
cmake -S . -B build -A x64
cmake --build build --config Release --target vemt_wrapper --parallel 4
copy .\build\Release\vemt_wrapper.dll ..\lib\
```

Finally, build the Zig executable:

```ps1
cd ..
zig build
```

Additionally, Python 3.9 or newer is required for automated model conversion during installation. However, it is not strictly required, if you prefer to convert models manually. To create the Python environment and install the dependencies from the `requirements.txt` file, run:

```ps1
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
```

## Usage

```
Usage:
    vemt list
    vemt remove <source_language> <target_language>
    vemt install <source_language> <target_language> [--python-path=<path>] [--quantization=<type>] [--no-input]
    vemt <source_language> <target_language> <input>
    
    Options:
        --python-path=<path>   Path to the Python executable [default: "python"].
        --quantization=<type>  Quantization type to use during model conversion
                                (int8|int8_float32|int8_float16|int8_bfloat16|int16|float16|bfloat16|float32).
        --no-input             Skips interactive model selection and automatically chooses the last model.
```

## Examples

List installed models:
```ps1
vemt list
```

Install an English-to-Finnish model with a specific Python executable and quantization type:
```ps1
vemt install en fi --python-path=".venv\Scripts\python.exe" --quantization="int8"
```

Translate a sentence:
```ps1
vemt en fi "Translated string"
```

Remove an installed model:
```ps1
vemt remove en fi
```

## Zig package

### Installation

VeMT can also be used as a Zig package, which exposes its `translate()` function. First, add the package as a dependency to your `build.zig.zon` with the following command.

```ps1
zig fetch --save git+https://github.com/AceHanded/VeMT.git
```

Next, add the following code to your `build.zig` to register the dependency and allow the package to be imported.

```zig
const vemt = b.dependency("vemt", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("vemt", vemt.module("vemt"));
```

### Example

```zig
const std = @import("std");
const vemt = @import("vemt");

pub fn main(init: std.process.Init) !void {
    const allocator: std.mem.Allocator = init.arena.allocator();

    const translated: []u8 = try vemt.translate(
        allocator,
        "path/to/ct2_model/",  // en-fi
        "path/to/source.spm",  // en
        "path/to/target.spm",  // fi
        "Translated string"
    );
    defer allocator.free(translated);

    std.debug.print("{s}\n", .{ translated });  // Käännetty merkkijono
}
```