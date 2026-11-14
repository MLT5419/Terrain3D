Terrain Edit Layers and Stamps
=============================

Terrain edit layers keep sculpting and material painting separate from the original terrain. A `Terrain3D` combines their source maps into one result for rendering, height queries and collision. These editing layers are different from the surface entries in `Terrain3DAssets`.

## Getting started

Open `addons/terrain_3d/extras/layers/layers_demo.tscn` for a working example. It instances an independent ground scene and two instances of the same hill Stamp scene. Both hills share their height data; one instance uses a sandstone skin. The source data and materials are separate `.res` files.

1. Add a `Terrain3DPaintLayer` beneath an existing `Terrain3D`, or create a scene whose root is `Terrain3DPaintLayer` or `Terrain3DStamp`.
2. Use **Create Layer Data**, then save its `Terrain3DLayerData` resource as an external `.res` file. Embedded data is also supported.
3. Select the layer in the Scene tree. The terrain toolbar edits that layer. Add material entries through its Asset Dock or configure its **Slots** in the Inspector.
4. Save the layer scene and its external resources. Instance that scene beneath the destination Terrain3D.

Nodes are processed in Scene tree order, from earlier contributions to later contributions. Wrapper nodes are traversed; another Terrain3D starts a separate composition context. **Enabled** controls participation of the layer and its descendants, **Locked** prevents brush editing, and **Erase Mode** removes this layer's coverage to reveal the layers below. The Node3D visibility switch is not the layer enable switch.

The parent owns vertex spacing, region size, mesh LODs, collision and terrain material settings. Fixed-grid paint layers use terrain/world coordinates and keep an identity transform. Use a Stamp for movable content. Region resizing is unavailable while edit layers are active; detach the layers before reslicing the base.

## Height composition

Each source sample has a height value and independent coverage. Untouched samples contribute nothing; an explicitly painted zero can replace the lower height.

* **Add** stores a relative height contribution: `result = lower + height * coverage * height_opacity`.
* **Replace** blends toward a target height: `result = lerp(lower, height, coverage * height_opacity)`.

Sculpt, Set Height and smoothing read the composition through the selected layer, excluding layers above it, and write back to that layer. Set Height uses the world height shown by the terrain tool. Layers above the selection can still cover the edit. Color and roughness painting are also supported. Region creation/removal, holes, navigation, autoshader painting and gradient tools are not layer brushes in this version; existing base terrain remains an input.

The compositor works in affected 32-sample tiles and uploads the affected terrain regions. Moving, disabling or deleting a Stamp also clears its previous footprint. Adding/removing regions rebuilds the GPU map arrays. Structural, binding and source-resource changes may require a broader rebuild. Large layer stacks add CPU and memory cost while authoring; composition is not intended as a per-frame animation system.

## Stamps, pivots and source data

`Terrain3DStamp` stores its content in local coordinates. Position, Y rotation, nonzero X/Z scaling, Y scaling and **Height Scale** affect its contribution. X/Z tilt is rejected because a general rotated surface cannot always be represented by a single height per horizontal position. Painting transforms the brush into source coordinates.

The **Pivot** is measured in source meters. It is independent from **Reference Height**, the source elevation subtracted before height scaling. For example, a mountain with elevations 100–130 can use a reference height of 100 to contribute 0–30 meters. Node Y position adds a masked height offset. No second floating surface is created.

Use **Center Pivot** to center on the stored source sample and instance bounds. It compensates the node position and ordinary child transforms so the existing placement stays fixed. Painting and erasing do not automatically recenter the pivot. Heightmap import centers it explicitly; source sample centers span `(width - 1) * spacing` by `(height - 1) * spacing`.

Assign a **Heightmap** texture and use **Import Heightmap**, or set **Capture Bounds** in world X/Z meters and use **Capture Terrain Region**. Capture takes a snapshot of the current result, including its painted surfaces. It does not create a live link back to that terrain. Adjust Reference Height and Add/Replace mode to choose how the captured elevations should be reused.

Repeated movement and rotation always sample the original data, avoiding cumulative resampling. Height and color use coverage-aware bilinear sampling; packed control values use nearest sampling. Final detail is limited by the parent terrain's vertex spacing. Painted UV angle is currently world oriented rather than continuously rotated with the Stamp.

Duplicated scene instances share their data resource by default. **Make Data Unique** creates an independent copy; save that copy to its own file. Brush undo stores copies of the changed source chunks and preserves the external resource's identity. Inspector properties and node transforms use the editor's ordinary undo history.

## Material slots and skins

A `Terrain3DLayerSlot` declares a stable **Key**, an optional **Default Resource**, and an optional **Preview Resource**. The resources are normal `Terrain3DTextureAsset` objects, supporting both texture inputs and PBR material inputs.

Source control maps use local slot indices. Keep painted slot order stable: reordering or deleting an entry changes the meaning of existing paint. Slot keys can use namespaces such as `surface.ground` or `ruins.special_stone`.

`Terrain3DLayerBindings` is an external resource containing material, mesh and scene dictionaries. Assign it to a layer instance for a local skin, or to the parent's **Layer Bindings** for a terrain-wide skin. Resolution follows:

`instance binding → parent binding → slot default`

An unattached layer additionally allows its Preview Resource for editing. Preview resources are not implicit defaults for an attached layer or an export. Missing bindings are shown as composition errors. A slot-only prefab without defaults remains an authoring template; bind and place it before exporting a usable standalone terrain.

The final palette is generated from the parent's authored assets and the actually painted, enabled layer slots. The same resource reference is reused; different resources remain separate even if their images match, because UV scale, tint and other terrain parameters can differ. Compilation copies asset metadata and remaps local IDs only in the final control map. It never assigns global IDs back into source assets or rewrites a shared layer's paint.

The existing limit remains **32 final terrain materials**, including authored base entries. Resource declarations do not expand the shader's capacity. The control format also still holds two surface IDs per control point. Material painting is categorical coverage/override with erase-to-reveal behavior; arbitrary transparent mixing of multiple edit layers is not supported. Source control pairs and their internal blend values can be retained when capturing terrain.

## Independent scenes and persistence

Without a containing Terrain3D, a layer creates a temporary terrain host using **Preview Vertex Spacing** and an optional **Preview Material**. The host uses the same compositor and renderer; it is internal and is not saved in the layer scene. On attachment to a parent terrain, the standalone host is removed.

Source maps use sparse 64×64 chunks with separate height/control/color coverage. Keep each collaborator's `.tscn`, source `.res` files, defaults and skin resources independent. Adding a default material to one layer does not require editing the parent asset list. A shared skin is still a shared file and should be coordinated like any other shared resource.

Existing base region files remain the base. Saving through Terrain3DData writes those original regions, not the derived result. Layer-only worlds do not require a base data directory. Direct height, region and import mutations on composed Terrain3DData are rejected; edit the selected layer or its source API instead. Read APIs return the final terrain. Returned Image/Region references must not be modified as a way to bypass the source model.

`Terrain3DLayerData.set_pixel()` writes height or color samples. For packed material IDs, call `begin_edit()`, `set_control()` and `end_edit()`; the integer bits must not be filtered as float values. Source spacing is expressed in meters and is independent of the destination grid. Save after preparing source scenes before running them directly from the editor.

## Export

Keep the Terrain3D editor plugin enabled. Export composes placed layers using their actual bindings and saves a platform-cooked bake containing final regions and a final asset palette. Authored layer nodes become plain scene markers; standalone layers receive an ordinary baked Terrain3D. Runtime does not execute the authoring stack or need image encoders for the baked result.

Selected bake and texture `.res` dependencies are explicitly staged, including when Godot reuses cached scene customization. Source maps, slot tables and preview resources are removed from these baked scene dependencies. An Export All Resources preset can still package authoring files that it explicitly includes elsewhere. Re-export after editing geometry, bindings or layer settings. Changing baked skins, procedural generators and spline layers are outside this version's authoring workflow.

## Objects attached to the composed surface

Add a `Terrain3DAttachmentGroup` below Terrain3D, a Layer, or a Stamp. In **Children** processing, each direct Node3D child is an independent placement; a scene instance is treated as one object. In **Rigid** processing the container itself is placed as one assembly. Its descendants keep their local transforms, including furniture inside a house. Nested attachment solvers stop at a rigid ancestor.

`Terrain3DAttachmentSettings` chooses how objects follow the final heightfield:

- **Keep Offset** records the original gap between the anchor and the surface.
- **Snap** places the anchor directly on the surface, plus Height Offset.
- **Align Normal** preserves the gap and tilts toward the terrain normal, limited by Max Tilt Degrees.
- **Footprint Max / Min / Average** sample local Support Points and choose a common root height. Max keeps all supports above the sampled surface; it does not detect mesh collisions.
- **Footprint Plane** fits a plane through the sampled heights, limits tilt, then averages the support heights.
- **None** keeps the authored pose.

Anchor is in object coordinates; Anchor Marker can name a descendant Marker3D instead. Support Points also use object coordinates. Require All Supports leaves the previous result in place if any support is outside the terrain or over a hole. Hide Without Surface optionally hides that result. Moving the object horizontally keeps its gap; moving it vertically edits the gap. Capture Current Offsets explicitly records new offsets. Update Attachments recalculates immediately.

Transforms are always solved from persistent source poses, so repeated updates do not add displacement. `Terrain3DAttachmentData` can be saved as an external `.res`; it stores stable child IDs, authored transforms, and offsets. Independent scene instances receive independent source records. A Stamp scales placement positions; Inherit Parent Scale optionally scales object geometry too. By default the geometry keeps its authored size.

The editor follows height changes automatically. At runtime placement is calculated once; enable Runtime Follow for changing terrain. Export saves the solved ordinary scene hierarchy and removes the attachment authoring scripts and source records. Full scenes keep their own scripts, collisions and child transforms. Objects sample the final terrain and do not deform the heightfield themselves.

## Painted vegetation, rocks and scene objects

Every Layer and Stamp has an **Instances** section. Use **Create Instance Data**, configure **Instance Slots**, then select the layer and use the existing mesh brush. Dragging a `Terrain3DMeshAsset` into the layer's Meshes dock creates a mesh slot; dragging a `.tscn` or `.glb` creates a full-scene slot. The edit button opens the slot, where **Kind** can select mesh instancing or a complete scene. Save `Terrain3DScatterData` as an external `.res` for collaboration. **Make Instances Unique** separates an independent copy; ordinary duplicates share the source intentionally.

`Terrain3DInstanceSlot` declares a stable Key, Category, Kind, Enabled switch and default/preview resources. `Terrain3DLayerBindings.meshes` and `.scenes` resolve these keys with the same precedence as terrain materials. A preview-only slot is usable in standalone editing; bind a real resource or supply a default before placing/exporting. Keep slot order stable after painting. Disabling a slot hides its output without deleting records. Source mesh IDs stay unchanged; the final palette contains cloned metadata with resolved IDs, with a limit of **256 final mesh assets** and 256 local instance slots per layer. Full-scene slots do not consume mesh palette entries.

The dock count shows source records for each local slot. Mesh output uses Terrain3D's existing cell-based MultiMesh/LOD renderer. Mesh imports extract geometry using the existing Terrain3DMeshAsset rules; choose a full scene for multiple separate objects, scripts, collision or interaction. Full scenes retain those nodes and therefore cost more than MultiMesh instances. Their root must be Node3D. Instance scenes cannot contain another Terrain3D, terrain editing layer or attachment container, which would create another authoring cycle.

Instance positions use the layer's source coordinates, including a Stamp's pivot and planar transform. Its placement scale moves the positions; geometry keeps its source size unless **Instance Placement → Inherit Parent Scale** is enabled. **Instance Placement** uses the common attachment settings. Source per-instance height offsets and mesh asset height offsets are also applied. Anchor Marker is available for full scenes; mesh slots use the numeric anchor/support points. Mesh vertex colors come from the brush; a full scene uses its own materials. The brush supports size, strength, shape, slope filtering, scale, spin, tilt, height variation and color variation. Layer placement samples the composed terrain; the base terrain's On Collision raycast brush is not supported for layer records.

Instance modes follow scene-tree order:

- **Add** contributes the layer's records.
- **Mask Lower** paints suppression coverage for records from earlier layers and the original terrain.
- **Replace** suppresses earlier records under the painted coverage, then contributes its own records.

Empty **Mask Keys** and **Mask Categories** affect everything below. Supplied filters must both match; the base terrain uses keys `base.mesh_0`, `base.mesh_1`, etc. and category `mesh`. A mask cannot remove later layers. **Erase Mode** (or Ctrl/invert with the instance brush) removes this layer's own records; in Mask Lower/Replace it also erases this layer's suppression coverage. It never deletes another layer's source records.

**Instance Opacity** deterministically thins existing records and scales suppression coverage. Changing it or recomposing does not roll new random placements. **Paint Density** controls new brush records. Suppression is a coverage map inside the scatter source, separate from the height/material maps. Holes, missing terrain, disabled layers and masks remove only derived output: moving a Stamp back onto valid terrain or disabling the mask restores its records. Brush undo restores source records and mask coverage without replacing the external resource.

Heights and materials compose first, instances blend next, then ordinary attachment groups solve against that final surface. Existing base meshes preserve their original height gap. A bulk instance is not an input to terrain height calculation. Instance compilation currently scans the participating source records; MultiMesh rendering remains cell based, but authoring very large populations can make recomposition expensive. This workflow targets editor composition and exported static scenes, rather than per-frame scatter simulation.

Export stores final mesh transforms in the baked terrain regions and writes full-scene instances as ordinary owned nodes. It removes the layer/attachment authoring data from the converted hierarchy. Scripts, collision and furniture remain part of their full scenes. An Export All Resources preset can still include unrelated authoring files explicitly.

Open `addons/terrain_3d/extras/layers/objects_demo.tscn` for mesh roles with two skins, complete scene instances, a lower-layer clearing mask, independently attached rocks, and a rigid cabin with furniture.
