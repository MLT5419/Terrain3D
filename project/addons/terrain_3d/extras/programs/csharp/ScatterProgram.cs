// Copyright © 2026 Terrain3D Contributors.
using Godot;
using GDict = Godot.Collections.Dictionary;
using GArray = Godot.Collections.Array;

namespace Terrain3DPrograms.Examples;

[Tool]
public partial class ScatterProgram : RefCounted
{
    public GDict Describe() => new()
    {
        ["reads"] = new GArray { "final_height", "mask?:terrain.clearance" },
        ["writes"] = new GArray { "instances" }, ["version"] = 1
    };

    public bool Generate(GodotObject context, GodotObject output)
    {
        var density = context.Call("parameter", "density", 0.15).AsDouble();
        var spacing = context.Call("get_spacing").AsDouble();
        var role = context.Call("parameter", "instance_role", "nature.grass").AsString();
        foreach (var point in context.Call("sample_points").AsVector2Array())
        {
            if (!double.IsFinite(context.Call("height", point).AsDouble()) ||
                context.Call("mask_weight", "terrain.clearance", point).AsDouble() >= 0.5 ||
                context.Call("random_at", point).AsDouble() >= Mathf.Clamp(density * spacing * spacing, 0.0, 1.0))
                continue;
            var scale = Mathf.Lerp(0.7f, 1.3f, (float)context.Call("random_at", point, 1).AsDouble());
            var basis = new Basis(Vector3.Up, (float)context.Call("random_at", point, 2).AsDouble() * Mathf.Tau).Scaled(Vector3.One * scale);
            output.Call("emit_instance", role, point.ToString(), new Transform3D(basis, new Vector3(point.X, 0, point.Y)));
        }
        return true;
    }
}
