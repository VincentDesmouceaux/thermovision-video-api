#include <metal_stdlib>
using namespace metal;

// Entrée: BGRA8Unorm
// Sortie: R32Float (score de "chaleur" visuelle par pixel)
kernel void heatScore(
    texture2d<uchar, access::read>  inTex  [[ texture(0) ]],
    texture2d<float, access::write> outTex [[ texture(1) ]],
    uint2 gid [[thread_position_in_grid]]
){
    uint W = outTex.get_width();
    uint H = outTex.get_height();
    if (gid.x >= W || gid.y >= H) return;

    uchar4 bgra = inTex.read(gid);
    // normalise en [0,1]
    float b = (float)bgra.x / 255.0;
    float g = (float)bgra.y / 255.0;
    float r = (float)bgra.z / 255.0;

    // Luma Rec.709
    float luma = dot(float3(r,g,b), float3(0.2126, 0.7152, 0.0722));
    // dominance du rouge
    float redDom = r / (g + b + 1e-4);
    // "chaleur" (rouge > vert/bleu)
    float warmBoost = max(r - max(g,b), 0.0);
    // saturation simple
    float cmax = max(r, max(g,b));
    float cmin = min(r, min(g,b));
    float sat  = (cmax - cmin) / (cmax + 1e-6);

    // Score final (borné)
    float score = luma * (0.5 + 0.5*sat) * (0.5 + 0.5*redDom) + warmBoost;
    score = clamp(score, 0.0, 1.0);

    outTex.write(score, gid);
}
