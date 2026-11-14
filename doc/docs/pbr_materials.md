Terrain Surface Layers and Portable Caches
==========================================

Each `Terrain3DTextureAsset` has a **Source Mode** dropdown:

* **Textures** uses the original albedo/height and normal/roughness/AO inputs. Existing resources default to this mode.
* **PBR Material** accepts a `StandardMaterial3D` or `ORMMaterial3D`. Edit its PBR properties in the embedded material inspector. Duplicate texture/color/roughness controls are hidden in this mode.

Switching modes retains both source configurations. UV Scale, displacement and detiling remain terrain-specific controls. Drag a material file from the FileSystem, or a material resource from the inspector, onto an Asset Dock texture entry to select PBR Material mode automatically.

Both inputs now use the same preprocessing, cache and GPU arrays. There are no separate Legacy and Material arrays or placeholder layers.

## AO premultiplication

**Premultiply AO** is a per-layer switch in PBR Material mode. By default AO is an independent shading channel. When enabled, preprocessing multiplies AO into albedo in linear color space and sets independent AO to one, preventing double occlusion.

This also darkens directly lit surfaces and changes the base color used for metallic reflections. Emission is retained. A layer with neither independent AO nor emission omits its auxiliary image; emission can therefore still require a third image when AO premultiplication is enabled.

## Unified channel layout

| Array | R | G | B | A |
| --- | --- | --- | --- | --- |
| Albedo / height | Base color R | Base color G | Base color B | Height |
| Surface | Normal X | Normal Y | Roughness | Metallic |
| Auxiliary, optional | Emission R | Emission G | Emission B | AO |

Albedo and Surface have one layer per texture ID. Auxiliary stores only layers that need it, with a small index table. A terrain with no auxiliary images has no full-resolution auxiliary allocation. Shader code reconstructs positive tangent-space normal Z, so normal maps must use the conventional positive-Z hemisphere.

Material mip chains are processed by semantic before packing: normals are normalized separately, masks stay linear, and colors are filtered in linear space. Emission uses a saved intensity scale to retain HDR values within cache quantization limits. Texture-mode conversion extracts the legacy AO from normal-vector length, keeps imported mip chains when dimensions match, and retains legacy AO-strength/height response, roughness offset and specular behavior. Repacking and compressed normal XY can produce small numerical or filtering differences from the original RGB-normal layout.

In the `Terrain3DAssets` inspector, **Texture Resolution** controls all arrays. Auto uses the largest requested material resolution or source texture dimension, rounded up to a power of two and capped at 4096. Inputs are resampled to this common square size; source files are unchanged. An explicit resolution makes the memory budget predictable. **Material Texture Size** remains a PBR layer's requested resolution when the shared setting is Auto.

## Embedded and external .res caches

The editor keeps a lossless RGBA8 master after channel packing and prepares GPU variants from it. It never creates an ASTC variant by recompressing a generated BC7 cache.

Every layer has **Cache Storage**:

* **Embedded** saves the master and prepared preview cache as subresources in the layer's owning resource/scene.
* **External .res** saves content-addressed binary resources in **Cache Directory**, initially `res://terrain3d_cache`. **Cache File** shows the master path. Identical inputs, resolution and AO settings reuse the same cache resource.

`Terrain3DTextureCache` stores the channel images, layout version, SHA-256 source signature, compression format and emission scale. Resource-file compression is lossless. External saves use a temporary file and rename it when complete; resource UIDs are registered against the final path. Runtime assets reference their selected cache as a normal Godot resource dependency.

Save the assets or containing scene after preprocessing. External cache files referenced by those assets belong with the project and should be versioned or regenerated before use. Old content-addressed variants are retained; remove them only after confirming that no scene or resource references them. Changing back to Embedded removes the external resource reference without deleting shared cache files.

Old embedded PBR caches and original texture assets are upgraded by opening and saving them in the editor. Previously exported packages must be re-exported with the updated extension. Runtime requires prepared caches and does not run image encoders. Pixel-producing material changes require an editor bake; source properties are authoring inputs rather than live runtime material parameters.

## Compression and platform selection

Set **Texture Compression** on the assets resource:

| Profile | Packed GPU format |
| --- | --- |
| BC7 | BPTC RGBA |
| ASTC 4x4 | ASTC LDR, 4x4 blocks, all RGBA channels |
| ETC2 RGBA8 | ETC2 RGB with full EAC alpha |
| BC3 | S3TC/DXT5 RGBA |
| RGBA8 | Uncompressed RGBA |
| Auto | Chooses a supported editor preview format; exporter selects a target profile |

Auto preview prefers BC7, then ASTC 4x4, ETC2, BC3 and RGBA8 according to device support. Auto export uses ASTC 4x4 for Android/iOS with the Mobile/Forward+ renderer, ETC2 for mobile Compatibility and Web, BC7 for other Forward+/Mobile targets, and BC3 for desktop Compatibility. Explicit profiles override this policy. Platform compression is performed in the editor/exporter; the required encoder must be available in that Godot build.

ASTC is not universal Web support: it requires the relevant browser/GPU extension. If a cooked format is unsupported, runtime decodes to RGBA8, provided the engine build includes its decoder. This fallback uses about four times the GPU texture memory of these 8-bit-per-pixel block formats, plus temporary decoding memory. Test the chosen profile and resolution on the target device. Mobile and Web still require the corresponding Terrain3D extension build and platform support.

Do not apply automatic normal-map compression to Surface: its blue and alpha channels contain roughness and metallic data. All array layers use one resolution, format and mip layout, so compression is selected for the assets resource rather than independently per layer.

## Exported resources

Keep the Terrain3D editor plugin enabled during export. It prepares the target format for both input modes and produces runtime copies containing only cooked cache references and shading parameters. Source materials, source textures, lossless masters and preview variants are not referenced by these copies. Authoring resources are retained.

The export plugin explicitly packages selected cooked `.res` files under its generated export directory and skips authoring `Terrain3DTextureCache` files, including unused platform variants. Other original source files can still be included by an Export All Resources preset or used elsewhere in the project. The exporter stages resources found in standalone assets and scene/resource properties, so cached export reuse does not omit external dependencies.

## Custom shaders and material features

The normal/surface array now uses layout version 2. The bundled lightweight shader is updated. Existing custom shaders that read `_texture_array_normal` as RGB normals must be migrated to normal XY, roughness B and metallic A, then declare `#define TERRAIN3D_TEXTURE_LAYOUT_VERSION 2`. The extension reports old overrides and uses its default shader until they are migrated. Minimum terrain shaders that do not read surface textures are unaffected.

The PBR adapter supports base color and texture, normal texture and strength, height and flip, roughness/metallic values and selected channels, ORM, AO/light affect, emission color/texture/operator/energy, specular and UV1 scale/offset. Height participates in blending; terrain displacement still uses the layer's displacement controls. Macro variation, wetness and color painting can modify the result.

This is opaque metallic/roughness PBR. ShaderMaterial, UV2-specific maps, source-material triplanar projection, clearcoat, rim, anisotropy, subsurface scattering, backlight, detail layers, refraction, source parallax, grow, transparency, independent lighting models and additional passes are not transferred. Material Warnings identifies enabled unsupported features. Use terrain projection and displacement for those terrain features.
