// Copyright © 2026 Terrain3D Contributors.
using Godot;
using GDict = Godot.Collections.Dictionary;
using GArray = Godot.Collections.Array;

namespace Terrain3DPrograms.Examples;

[Tool]
public partial class NoiseHeightProgram : RefCounted
{
    public GDict Describe() => new()
    {
        ["reads"] = new GArray(), ["writes"] = new GArray { "height" }, ["version"] = 1
    };

    public bool Generate(GodotObject context, GodotObject output)
    {
        using var noise = new FastNoiseLite();
        noise.Seed = context.Call("get_seed").AsInt32();
        noise.Frequency = (float)context.Call("parameter", "frequency", 0.035).AsDouble();
        var amplitude = context.Call("parameter", "amplitude", 6.0).AsDouble();
        var baseHeight = context.Call("parameter", "base_height", 0.0).AsDouble();
        foreach (var point in context.Call("sample_points").AsVector2Array())
            output.Call("write_height", point, baseHeight + amplitude * noise.GetNoise2Dv(point));
        return true;
    }
}
