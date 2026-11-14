Terrain Programs
================

Terrain programs generate derived terrain data, semantic masks, instances, meshes and decals. Programs can be mounted on Terrain3D, a Layer/Stamp, or a material role. Their outputs remain separate from hand-painted source data. Open `demo/programs/programs_demo.tscn` for a noise landscape, slope-based material classification, material-scoped trees, and a cabin with a fitted foundation, vegetation clearance and a dirt decal.

## Configure a program

Add a `Terrain3DProgramSlot` to **Programs**. Choose a `.gd` or `.cs` file in **Program**, set a unique Key, stage, source Bounds, seed and parameters. Save the slot as `.tres`/`.res` to share its configuration. Each mounting location gets its own execution object; instance state is never stored in the shared configuration.

- **Terrain3D → Programs** operates in world X/Z meters. Use Before Authoring for a generated base, or After Authoring for a terrain-wide modifier.
- **Layer/Stamp → Programs** uses that layer's source coordinates. A Stamp's pivot and placement transform apply to the output. Before/After Authoring selects whether the derived contribution precedes or follows that layer's painted maps.
- **Terrain3DLayerSlot → Programs** is restricted to that role's visible CPU coverage. An empty list can inherit the bound Terrain3DTextureAsset's Programs; disable Inherit Asset Programs to suppress those defaults.
- **Terrain3DTextureAsset → Programs** also works on the base palette. Set Role Key for a stable logical name; otherwise the base role is `base.material_0`, `base.material_1`, etc.

Shader-only autoshader classification cannot be read back as a CPU material mask. Use an explicit surface classifier for program-driven vegetation. Role names and the contributing layer remain distinct even when several roles share one texture asset. Generated output never stores compiled GPU material IDs in authoring data.

The sample spacing defaults to the owning source map's spacing, or the parent terrain's vertex spacing. Generation uses 32-by-32 source-cell chunks. Outputs from those chunks are merged before height/material interpolation, including Replace-mode boundaries. Automatic mode rebuilds affected chunks when declared inputs change. Manual mode builds on initial load and then retains its output until Regenerate. Pure programs with no reads reuse their chunks until their configuration changes. The Regenerate button forces a rebuild in either mode.

Source scenes execute programs once when run directly. Exported scenes use a static bake and execute no program controllers. Runtime streaming and per-frame program updates are not part of this interface. Generation is currently synchronous on the main thread, with bounded chunks and a 4096-chunk limit per binding; use manual updates for expensive programs.

## Language-neutral lifecycle

Scripts extend Godot `RefCounted` or `Resource`. GDScript uses `@tool`; C# uses `[Tool]`. Each script must have a zero-argument constructor. C# programs inherit a Godot class directly and do not need to inherit any GDScript class.

| Callback in GDScript | Callback in C# | Purpose |
| --- | --- | --- |
| `describe()` | `Describe()` | Optional dictionary declaring reads, writes and a version. |
| `on_attach(context)` | `OnAttach(context)` | Optional, once for each execution instance. |
| `generate(context, output)` | `Generate(context, output)` | Required; return `true` when the buffered result is complete. |
| `on_applied(context)` | `OnApplied(context)` | Optional, after the complete terrain transaction is published. |
| `on_detach(context)` | `OnDetach(context)` | Optional cleanup on removal or script replacement. |

The context and output are Godot objects. C# accesses their methods with `GodotObject.Call`; use Variant-compatible Godot types and `Godot.Collections.Dictionary/Array` in descriptors. Both languages enter the same scheduler and use the same buffered output API. The C# class name must match its filename, the file must be included in the project's `.csproj`, and the project must be built in Godot .NET with a suitable .NET SDK.

Copy the examples from `demo/programs/csharp/` into your .NET project's script directory and select the copied `.cs` file. That examples directory is ignored by Godot's asset scan so a standard Godot project does not acquire a C# requirement. The example classes use their own namespace. Godot's .NET platform/export restrictions still apply to a .NET project.

A successful configuration change can be undone through the editor's normal property history; regeneration derives the corresponding output again. Manual configurations require Regenerate after undoing a setting. Program scripts are trusted project code: keep generation within the context/output contract and keep cleanup callbacks limited to controller state.

## Stages and dependencies

**Height** programs read their input terrain below their own contribution and emit height/clearance data. **Surface** programs read the completed heightfield and emit material, color/roughness or semantic masks. **Content** programs read final height/material classification and emit instances, meshes or decals.

Declare `height` or `final_height` before querying height/slope. `final_height` is invalid for a Height program. `final_material` is invalid for Height and Surface programs. Declare named masks as `mask:role` in reads/writes; `mask?:role` is an optional input. Consumers wait for producers, and cycles and later-stage dependencies are rejected. Multiple producers of a semantic mask combine by maximum coverage.

A failed generation, invalid dependency, undeclared output role, out-of-chunk write or stale input revision leaves the previous published terrain in place. Results replace the same program's prior output instead of appending another copy. Keep emitted object IDs stable. Disabled or removed programs clear only their own derived output.

Declare all mesh/material roles through Material Slots and Instance Slots, or inherit them from the owning layer. Declare external textures, materials and other assets in Resources or the typed slot tables so export can discover them. Reference paths are relative to the owning layer, or Terrain3D for a root/base-material program. Model references expose authored poses, excluding the existing attachment solver's displacement.

## Context and output API

Useful context methods include `get_bounds()`, `get_spacing()`, `sample_points()`, `parameter(key, fallback)`, `resource(key)`, `height(point)`, `slope(point)`, `coverage(point, role)`, `mask_weight(key, point)`, `random_at(point, stream)`, `reference_pose(index)`, `to_world(point)` and `to_source(world)`.

Positions use source X/Z meters. `random_at` derives its value from the binding seed, persistent program UID, source cell and stream; temporary viewports and execution order do not affect it. Context queries are intended for the current generation/application callbacks, not as long-lived scene handles.

Output methods are:

- `write_height(point, value, coverage)` writes a raw source height using the slot's Add/Replace mode. `to_source_height(world_height)` converts a world target height for Replace output.
- `write_material(point, role, coverage)` writes a declared local material role. Material coverage follows the existing categorical terrain-paint rules.
- `write_color(point, color, coverage)` writes color with roughness in alpha.
- `write_mask(role, point, coverage)` writes a declared semantic mask.
- `emit_instance(role, id, transform, color, offset, align_normal)` uses existing mesh/complete-scene slots and their renderer. Material-bound instances use deterministic thinning for fractional material blends.
- `emit_mesh(id, transform, mesh, material, options)` publishes an ordinary mesh. Options include `snap`, `height_offset`, `inherit_scale` and `collision`.
- `emit_decal(id, transform, textures, size, options)` publishes a native Decal. Textures use `albedo`, `normal`, `orm` and `emission` keys. Options include `snap`, `height_offset`, `inherit_scale`, `modulate`, `cull_mask`, `distance_fade` and `fade_begin`.

Native decals require Forward+ or Mobile; Compatibility does not render them. Mobile limits decals per mesh resource. Configure terrain/object visibility layers and decal Cull Mask when projections must affect only the ground. Native decals have fixed PBR channels and do not accept arbitrary custom shaders. Baked terrain color/material coverage is a separate output; this version does not bake arbitrary decal normals/ORM into extra terrain texture channels.

## Models controlling terrain

Assign `Terrain3DTerrainInteraction` to an attachment group's **Terrain Interaction**. Children processing creates an interaction for each direct target; Rigid processing uses the assembly as a whole. Furniture keeps its local transforms.

**Terrain Follows Model** keeps the authored model pose and generates a contact plane. **Place Then Terraform** first places the contact anchor on the unmodified input terrain, freezes that plan for the transaction, then builds its foundation. An enabled interaction takes vertical authority over the usual attachment settings, preventing the old terrain-relative gap from being applied a second time. Disabling it returns to the group's ordinary attachment policy.

Configure a model-local footprint polygon, anchor or Anchor Marker, world-space margin/falloff, maximum cut/fill, and clearance. The footprint defines contact explicitly; furniture, roofs and overhangs do not enlarge it. Vertical contact planes cannot be represented by a heightfield and are rejected.

Clearance emits `terrain.clearance`. The default excluded category is `vegetation`; add `mesh` to affect original base mesh instances. It filters derived output without deleting painted source records. Optional decal textures create a managed foundation decal after the final surface is known. Moving or disabling the reference clears its old footprint and outputs.

The foundation programs read the terrain before their own output, so repeated regeneration does not accumulate height or chase the model's solved pose. Overlapping interactions follow contribution order. Unbounded bidirectional constraint solving is not performed.

## Persistence and export

Keep programs and their asset declarations as shared configuration resources; keep hand-painted LayerData and ScatterData as their own source files. Editor preview outputs are internal and are regenerated rather than serialized into the authored scene. Saving a terrain's region directory preserves its canonical base.

Export resolves bindings, regenerates complete outputs, cooks the final asset palette, and stores terrain regions/mesh instances in the existing bake format. Managed meshes, decals and complete scene objects become ordinary owned nodes, with collision and ordinary scene ownership preserved. Program configuration references are removed from converted terrain/materials. A .NET assembly may still contain authoring classes compiled into that assembly, and an Export All Resources preset may include unrelated authoring files explicitly.
