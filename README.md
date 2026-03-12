# MachOInspect

A macOS command-line tool for inspecting Mach-O binaries to detect and manage Objective-C `+load` methods. Built on top of [MachOView](https://github.com/gdbinit/MachOView).

## Overview

MachOInspect provides two utilities for managing `+load` methods in iOS/macOS projects:

- **MachOLoadChecker** — Scans a Mach-O binary and checks whether any class/category implementing `+load` is missing from a configuration JSON file. Fails the build if undeclared `+load` methods are found.
- **MachOLoadModifier** — Renames symbols in the Mach-O binary (e.g., renames `load` → `czld` in `__objc_methname`) to redirect method dispatch.

## How It Works

The tool parses the Mach-O binary and reads two ObjC runtime sections:

- `__objc_nlclslist` — non-lazy classes (classes that implement `+load`)
- `__objc_nlcatlist` — non-lazy categories (categories that implement `+load`)

It then compares the found classes/categories against a `load_config.json` file that declares all known `+load` implementors.

### Edge Cases Handled

| Case | `__objc_nlclslist` | `__objc_nlcatlist` | Notes |
|------|--------------------|--------------------|-------|
| Class and category both implement `+load` | has class | has category | both checked |
| Only class implements `+load` | has class | empty | class checked |
| Only a category implements `+load` (1 category) | has class | empty | class used as proxy |
| Only categories implement `+load` (multiple) | empty | has categories | categories checked |

## Configuration File Format

`load_config.json` declares all classes and categories that are allowed to have `+load` methods, grouped by execution priority:

```json
{
    "mainlist": [
        { "cls": "MyClass", "cat": "" },
        { "cls": "MyClass", "cat": "MyCategory" }
    ],
    "mainbglist": [],
    "delaylist": []
}
```

- **`mainlist`** — `+load` methods executed on the main thread at launch
- **`mainbglist`** — `+load` methods executed on a background thread at launch
- **`delaylist`** — `+load` methods executed with a delay
- `"cat": ""` — a class-level `+load`; `"cat": "SomeName"` — a category-level `+load`

## Build Script Integration

Add the following to your Xcode build phase (Run Script):

```shell
# Define paths
machOPath="${BUILT_PRODUCTS_DIR}/${TARGET_NAME}.app/${TARGET_NAME}"
currentDir=$(dirname "$PWD")
loadJsonPath="${currentDir}/LoadMangerDemo/LoadManageScript/load_config.json"

# Step 1: Rename load -> czld in __objc_methname
./LoadManageScript/MachOLoadModifier "${machOPath}" "${machOPath}" "load" "czld" "C String Literals" "(__TEXT,__objc_methname)"

# Step 2: Check for undeclared +load methods
./LoadManageScript/MachOLoadChecker "${machOPath}" "${loadJsonPath}"
exitCode=$?

if [ $exitCode -ne 0 ]; then
    echo "[ERROR]: New load method class are added in the project but load_config.json doesn't update."
    exit 1
fi
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success — no undeclared `+load` methods found |
| `1` | Failed to parse the Mach-O file |
| `2` | Unable to get load class info from the binary |
| `3` | Undeclared `+load` methods found in the binary |

## Build Requirements

- macOS with Xcode
- C++11 standard library
- Build settings:
  - **Prefix header**: `MachOInspect/Prefix.pch`
  - **Header search paths**: `$(SRCROOT)`, `$(SRCROOT)/capstone/include`
  - **C++ Standard Library**: `libc++` (C++11)
  - All `.c` and `.inc` files under `capstone/` must be compiled

## Dependencies

- [Capstone](https://www.capstone-engine.org/) — disassembly engine (ARM, ARM64, x86, PowerPC; bundled in `MachOInspect/capstone/`)
- [MachOView](https://github.com/gdbinit/MachOView) — Mach-O parsing framework (adapted in `MachOInspect/machoview/`)

## Project Structure

```
MachOInspect/
├── MachOInspect/
│   ├── main.m                  # Entry point
│   ├── CMDManager.h/.mm        # CLI argument handling and +load comparison logic
│   ├── capstone/               # Capstone disassembler (ARM, ARM64, x86, PPC)
│   ├── machoview/              # MachOView parsing library
│   │   ├── MachOLayout.h/.mm   # Mach-O layout; reads __objc_nlclslist / __objc_nlcatlist
│   │   └── ...
│   └── mach-o/                 # Mach-O structure headers
└── MachOHackedProduct/         # Sample binaries and JSON for testing
    └── load_method.json        # Example load_config.json
```
