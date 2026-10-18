# nebelkern-metal ✦

> **Native macOS Extended Dynamic Range (EDR) Particle Nebula**  
> Powered by MetalKit, MSL Compute Shaders, and Apple Silicon Unified Memory Architecture.

---

## Technical Architecture

```
nebelkern-metal
├── Shaders.metal          # MSL 3D Curl Noise Compute Kernel + Gaussian Optical Glow
├── Sources/
│   └── nebelkern-metal/
│       ├── Models.swift   # Shared memory alignment (16-byte) & Parametric Silhouette
│       ├── Renderer.swift # MTKViewDelegate driving Compute & Render Encoders
│       └── main.swift     # AppKit window manager + SwiftUI HUD + Wallpaper mode
└── Package.swift          # SPM Manifest (macOS 13+)
```

### 1. Zero-Copy Compute Pipeline
Utilizes Apple Silicon's **Unified Memory Architecture (UMA)** (`.storageModeShared`) to allow compute kernels to mutate particle positions directly in GPU VRAM without CPU-GPU bus transfer bottlenecks.

### 2. 3D Curl Noise Displacement
Particle advection is driven by a divergence-free 3D curl velocity field ($\nabla \times \vec{F}$), eliminating random noise chaos and creating laminar fluid cosmic streams across the humanoid silhouette.

### 3. Extended Dynamic Range (EDR / HDR)
Configured with `.rgba16Float` render target format and `wantsExtendedDynamicRangeContent = true`. On Liquid Retina XDR displays (MacBook Pro / Apple Pro Display XDR), optical core clusters exceed `1.0` peak luminance, physically glowing brighter than UI elements.

### 4. Live Wallpaper Mode
Integrates directly with macOS WindowServer (`CGWindowLevelForKey(.desktopWindow)`), allowing the visual to run as a 60 FPS live wallpaper behind all desktop icons and Finder items.

---

## Build & Run

### Terminal
```bash
swift run
```

### Xcode
```bash
open Package.swift
```

Select `nebelkern-metal` target and press **⌘R**.

---

Copyright © 2026 Shikhar Thakur.

Released under the MIT License — see [LICENSE](LICENSE).
