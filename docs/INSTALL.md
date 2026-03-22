# Installation

## Prerequisites

| Tool   | Version | Notes                                                         |
|--------|---------|---------------------------------------------------------------|
| Git    | any     | For cloning repositories                                      |
| CMake  | 3.22+   | [Download](https://cmake.org/download/)                       |
| Python | 3.x     | [Download](https://www.python.org/downloads/)                 |
| Zig    | 0.15.2  | [Download](https://ziglang.org/download/); select **0.15.2**  |

## Build

1. **Download and install CMake** from <https://cmake.org/download/>. Verify your installation:

    ```sh
    cmake --version  # Should print 3.22 or higher
    ```

2. **Download and install Python** from <https://www.python.org/downloads/>. Any Python 3.x release should suffice. Verify your installation:

    ```sh
    python --version  # Should print 3.0 or higher
    ```

3. **Download and install Zig 0.15.2** from <https://ziglang.org/download/>. Verify your installation:

    ```sh
    zig version  # Should print 0.15.2
    ```

4. **Clone Dawn:**

    ```sh
    git clone https://github.com/google/dawn.git
    cd dawn
    git checkout v20260320.180003
    cd ..
    ```

5. **Clone Emscripten SDK (emsdk):**

    ```sh
    git clone https://github.com/emscripten-core/emsdk.git
    cd emsdk
    git checkout 5.0.3
    cd ..
    ```

6. **Clone Ardapoeia:**

    ```sh
    git clone https://github.com/William65536/ardapoeia.git
    cd ardapoeia
    ```

7. **Build:**\
    Replace the paths to `emsdk` and `dawn` with wherever you cloned them:

    ```sh
    zig build -Doptimize=ReleaseSmall -Demsdk=/path/to/emsdk -Ddawn=/path/to/dawn
    ```

## Usage

Create a simple HTTP server:

```sh
cd zig-out/dist && python -m http.server
```

Open <http://localhost:8000> in a browser with WebGPU support. Chrome or any Chromium‑based browser is recommended. Firefox and Safari may require enabling flags.
