# Terrain3D demos

Open the repository's `project/project.godot` to use these scenes. The installable plugin lives in `addons/terrain_3d`; its runtime and editor code do not depend on this demo directory.

| Scene | Features |
| --- | --- |
| `Demo.tscn` | Main terrain, ocean and GPU particle demonstration. |
| `layers/layers_demo.tscn` | Independent layers, reusable Stamps and material skins. |
| `layers/objects_demo.tscn` | Mesh and scene scattering, clearing masks, attached rocks and a rigid cabin. |
| `programs/programs_demo.tscn` | Terrain programs, material classification, trees, model foundations and decals. |
| `csharp/CodeGeneratedCSDemo.tscn` | Terrain generated through C#; requires Godot .NET and a built project. |

Reusable GPU particle example files are in `particles/`. GDScript program implementations are provided by the plugin's `src/programs/builtin/`; C# program examples are in `programs/csharp/` with setup instructions in the Terrain Programs guide. Shared resources for the layer and program demos are in `layers/`.
