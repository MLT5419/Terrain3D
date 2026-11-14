PBR Material Layers
===================

Each `Terrain3DTextureAsset` has a **Source Mode** dropdown:

* **Textures** retains the original albedo/height and normal/roughness/AO workflow. Existing resources default to this mode.
* **PBR Material** accepts a `StandardMaterial3D` or `ORMMaterial3D`. Edit its PBR properties in the embedded material inspector. Duplicate texture/color/roughness controls are hidden in this mode.

Switching the dropdown retains both source configurations. UV Scale, displacement and detiling remain terrain-specific controls in both modes. A texture list can contain both types of layer and use the existing painting, height blending, autoshading, projection, dual scaling and displacement features.

Drag a material file from the FileSystem, or a material resource from the inspector, onto a texture entry in the Asset Dock to select PBR Material mode automatically. Replacing an existing entry this way preserves its texture-mode configuration.

## AO premultiplication

**Premultiply AO** is a per-layer switch in PBR Material mode. By default, AO is preserved as an independent shading channel. When enabled, the preprocessor multiplies AO into the albedo in linear color space and sets the independent AO channel to one, preventing double occlusion.

This is an artistic/performance tradeoff: baked AO also darkens direct lighting and changes the base color used for metallic reflections. Emission is preserved regardless of this switch. If no independent AO or emission is needed, the auxiliary texture is omitted. Therefore the switch does not guarantee a two-texture layer when emission is enabled.

## Preprocessing and storage

The editor generates these packed textures:

| Texture | R | G | B | A |
| --- | --- | --- | --- | --- |
| Albedo / height | Base color R | Base color G | Base color B | Height |
| Surface | Normal X | Normal Y | Roughness | Metallic |
| Optional auxiliary | Emission R | Emission G | Emission B | AO |

The shader reconstructs the positive tangent-space normal Z. Normal direction, color and scalar mip chains are generated separately before packing. Colors are filtered in linear space. Emission is normalized with a saved intensity scale so HDR values are retained within the quantization limits of the cache.

Material Texture Size selects the requested resolution. Material layers sharing an assets resource use its largest requested resolution. Original texture-mode import requirements are unchanged. Material arrays store only material layers; the auxiliary array stores only layers that need it. Mixed-mode terrains also keep placeholder entries in the legacy arrays, which costs additional VRAM.

Generated images use **BC7**, with all four channels retained. This version targets desktop renderers/devices that support BC7. It does not generate ASTC/ETC2 alternatives for mobile/web exports. Do not treat the Surface texture as a conventional normal texture or run automatic normal-map compression on it: that would discard the roughness and metallic channels.

The cache is embedded in the texture asset and includes a source signature. Pixel changes rebuild it; tint, UV transforms, normal strength, specular and AO light affect stay shader parameters. Source textures are not modified. **Save the assets resource or containing scene after preprocessing**, preferably as a binary `.res` for larger caches. Exported games upload the saved images without compression or image conversion at startup. Runtime changes to pixel-producing source properties require a new editor bake; these are authoring inputs, not live runtime material parameters.

With the Terrain3D editor plugin enabled, export customization replaces PBR layers with runtime copies containing their cache and material parameters. The source material and inactive texture-mode references are removed from those copies, avoiding unnecessary source-texture loading. Authoring resources are unchanged. Source files may still be included by an "Export all resources" preset or referenced by other objects. Exported PBR layers have no editable source material or inactive texture configuration; authoring mode switching is an editor feature.

## Supported material properties

Supported: base color and texture, normal texture and strength, height texture and flip, roughness/metallic values and selected texture channels, ORM channel layout, AO and light affect, emission color/texture/operator/energy, specular, and UV1 scale/offset. Height feeds terrain blending; physical displacement still uses the terrain layer's displacement controls. The terrain's normal scaling, macro variation, wetness and color painting can further modify the result.

This adapter covers opaque metallic/roughness PBR, rather than every rendering feature exposed by `BaseMaterial3D`. ShaderMaterial, UV2-specific maps, source-material triplanar projection, clearcoat, rim, anisotropy, subsurface scattering, backlight, detail layers, refraction, source parallax, grow, transparency, custom lighting modes and additional passes are not transferred. When relevant options are enabled, the inspector displays Material Warnings. Use the terrain's projection and displacement controls for those terrain features.
