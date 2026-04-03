import * as THREE from "three";
import "./styles.css";

function resolveDownloadUrl() {
  const { hostname, pathname } = window.location;
  const pagesHost = hostname.match(/^([^.]+)\.github\.io$/);

  if (pagesHost) {
    const owner = pagesHost[1];
    const repo = pathname.split("/").filter(Boolean)[0] ?? `${owner}.github.io`;
    return `https://github.com/${owner}/${repo}/releases/latest`;
  }

  return "https://github.com/OWNER/REPO/releases/latest";
}

function mulberry32(seed) {
  let state = seed >>> 0;

  return () => {
    state += 0x6d2b79f5;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function buildPointField(size, cellCount, seed) {
  const random = mulberry32(seed);
  const cellSize = size / cellCount;
  const points = new Float32Array(cellCount * cellCount * cellCount * 3);

  for (let z = 0; z < cellCount; z += 1) {
    for (let y = 0; y < cellCount; y += 1) {
      for (let x = 0; x < cellCount; x += 1) {
        const index = ((z * cellCount + y) * cellCount + x) * 3;
        points[index] = (x + random()) * cellSize;
        points[index + 1] = (y + random()) * cellSize;
        points[index + 2] = (z + random()) * cellSize;
      }
    }
  }

  return { cellCount, cellSize, size, points };
}

function toroidalDelta(a, b, period) {
  const direct = Math.abs(a - b);
  return Math.min(direct, period - direct);
}

function sampleWorley(field, x, y, z) {
  const { cellCount, cellSize, size, points } = field;
  const cx = Math.floor(x / cellSize);
  const cy = Math.floor(y / cellSize);
  const cz = Math.floor(z / cellSize);
  let nearest = Number.POSITIVE_INFINITY;

  for (let oz = -1; oz <= 1; oz += 1) {
    for (let oy = -1; oy <= 1; oy += 1) {
      for (let ox = -1; ox <= 1; ox += 1) {
        const ix = (cx + ox + cellCount) % cellCount;
        const iy = (cy + oy + cellCount) % cellCount;
        const iz = (cz + oz + cellCount) % cellCount;
        const index = ((iz * cellCount + iy) * cellCount + ix) * 3;
        const dx = toroidalDelta(x, points[index], size);
        const dy = toroidalDelta(y, points[index + 1], size);
        const dz = toroidalDelta(z, points[index + 2], size);
        const distance = Math.sqrt(dx * dx + dy * dy + dz * dz);

        if (distance < nearest) {
          nearest = distance;
        }
      }
    }
  }

  return nearest / (Math.sqrt(3) * cellSize);
}

function buildWorleyVolume(size, frequencies, seed) {
  const fields = frequencies.map((cellCount, index) =>
    buildPointField(size, cellCount, seed + index * 101),
  );
  const data = new Uint8Array(size * size * size * 4);

  for (let z = 0; z < size; z += 1) {
    for (let y = 0; y < size; y += 1) {
      for (let x = 0; x < size; x += 1) {
        const sampleX = x + 0.5;
        const sampleY = y + 0.5;
        const sampleZ = z + 0.5;
        const index = ((z * size + y) * size + x) * 4;

        for (let channel = 0; channel < 4; channel += 1) {
          const value = 1 - sampleWorley(fields[channel], sampleX, sampleY, sampleZ);
          data[index + channel] = Math.max(0, Math.min(255, Math.round(value * 255)));
        }
      }
    }
  }

  const texture = new THREE.Data3DTexture(data, size, size, size);
  texture.format = THREE.RGBAFormat;
  texture.type = THREE.UnsignedByteType;
  texture.minFilter = THREE.LinearFilter;
  texture.magFilter = THREE.LinearFilter;
  texture.wrapS = THREE.RepeatWrapping;
  texture.wrapT = THREE.RepeatWrapping;
  texture.wrapR = THREE.RepeatWrapping;
  texture.unpackAlignment = 1;
  texture.needsUpdate = true;

  return texture;
}

const shapeNoise = buildWorleyVolume(32, [3, 5, 7, 11], 1337);
const detailNoise = buildWorleyVolume(16, [4, 6, 8, 10], 7331);

const downloadLink = document.querySelector("#download-link");
if (downloadLink) {
  downloadLink.href = resolveDownloadUrl();
}

const canvas = document.querySelector(".hero-canvas");
const renderer = new THREE.WebGLRenderer({
  antialias: true,
  alpha: true,
  canvas,
  powerPreference: "high-performance",
});
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 1.5));
renderer.setClearAlpha(0);

const scene = new THREE.Scene();
const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
const geometry = new THREE.PlaneGeometry(2, 2);

const material = new THREE.ShaderMaterial({
  glslVersion: THREE.GLSL3,
  uniforms: {
    uTime: { value: 0 },
    uResolution: { value: new THREE.Vector2(1, 1) },
    uPointer: { value: new THREE.Vector2(0, 0) },
    uSunUv: { value: new THREE.Vector2(0.5, 0.5) },
    uSunBaseUv: { value: new THREE.Vector2(0.5, 0.5) },
    uShapeNoise: { value: shapeNoise },
    uDetailNoise: { value: detailNoise },
  },
  vertexShader: `
    void main() {
      gl_Position = vec4(position, 1.0);
    }
  `,
  fragmentShader: `
    precision highp float;
    precision highp sampler3D;

    uniform float uTime;
    uniform vec2 uResolution;
    uniform vec2 uPointer;
    uniform vec2 uSunUv;
    uniform vec2 uSunBaseUv;
    uniform sampler3D uShapeNoise;
    uniform sampler3D uDetailNoise;

    out vec4 fragColor;

    vec2 intersectBox(vec3 ro, vec3 rd, vec3 boxMin, vec3 boxMax) {
      vec3 tMin = (boxMin - ro) / rd;
      vec3 tMax = (boxMax - ro) / rd;
      vec3 t1 = min(tMin, tMax);
      vec3 t2 = max(tMin, tMax);
      float nearT = max(max(t1.x, t1.y), t1.z);
      float farT = min(min(t2.x, t2.y), t2.z);
      return vec2(nearT, farT);
    }

    float phaseHG(float g, float cosTheta) {
      float gg = g * g;
      return (1.0 - gg) / pow(1.0 + gg - 2.0 * g * cosTheta, 1.5) * 0.079577;
    }

    vec4 sampleShapeSet(vec3 p, vec3 wind) {
      return texture(uShapeNoise, fract(p * vec3(0.18, 0.11, 0.18) + wind));
    }

    vec4 sampleDetailSet(vec3 p, vec3 wind) {
      return texture(uDetailNoise, fract(p * vec3(0.56, 0.34, 0.56) - wind * 1.7));
    }

    float sampleShape(vec4 low) {
      return low.r * 0.44 + low.g * 0.24 + low.b * 0.18 + low.a * 0.14;
    }

    float sampleDetail(vec4 high) {
      return high.r * 0.42 + high.g * 0.24 + high.b * 0.2 + high.a * 0.14;
    }

    float densityAt(vec3 p, vec3 wind) {
      vec4 macroField = texture(uShapeNoise, fract(p * vec3(0.045, 0.022, 0.045) + wind * 0.18));
      vec4 macroFieldB = texture(uShapeNoise, fract(p * vec3(0.072, 0.036, 0.072) - wind * 0.16 + vec3(0.31, 0.0, 0.17)));
      float clusterMaskA = smoothstep(0.5, 0.78, macroField.r);
      float clusterCoreA = smoothstep(0.42, 0.82, macroField.g);
      float clusterMaskB = smoothstep(0.52, 0.8, macroFieldB.b);
      float clusterCoreB = smoothstep(0.44, 0.84, macroFieldB.a);
      float clusterGap = 1.0 - smoothstep(0.2, 0.48, max(macroField.b, macroFieldB.g));
      float islandA = clusterMaskA * (0.66 + clusterCoreA * 0.56);
      float islandB = clusterMaskB * (0.58 + clusterCoreB * 0.48);
      vec2 macroUvA = p.xz * 0.145 + wind.xz * 0.24 + (macroField.rg - 0.5) * 0.28;
      vec2 macroUvB = p.xz * 0.19 - wind.xz * 0.18 + (macroFieldB.ba - 0.5) * 0.22 + vec2(0.37, 0.11);
      vec2 clusterCellA = fract(macroUvA) - 0.5;
      vec2 clusterCellB = fract(macroUvB) - 0.5;
      float clusterEnvelopeA = 1.0 - smoothstep(0.22, 0.54, length(clusterCellA * vec2(0.9, 1.12)));
      float clusterEnvelopeB = 1.0 - smoothstep(0.18, 0.42, length(clusterCellB * vec2(1.0, 0.82)));
      float clusterEnvelope = max(clusterEnvelopeA, clusterEnvelopeB * 0.84);
      float islandMask = clamp((max(islandA, islandB) - clusterGap * 0.12) * (0.42 + clusterEnvelope * 0.58), 0.0, 1.0);
      float clusterCore = max(clusterCoreA, clusterCoreB);

      if (islandMask <= 0.02) return 0.0;

      float coverage = texture(uShapeNoise, fract(p * vec3(0.05, 0.02, 0.05) + wind * 0.45)).r;
      float cellMask = texture(uShapeNoise, fract(p * vec3(0.08, 0.03, 0.08) + wind * 0.7)).g;
      float towerMask = texture(uShapeNoise, fract(p * vec3(0.035, 0.02, 0.035) + wind * 0.32)).b;
      float shelfMask = texture(uShapeNoise, fract(p * vec3(0.11, 0.06, 0.11) - wind * 0.2)).a;
      float bottom = mix(0.2, 0.48, smoothstep(0.18, 0.82, coverage)) + (1.0 - islandMask) * 0.1;
      float top = mix(0.9, 1.85, smoothstep(0.4, 0.95, max(cellMask, towerMask)));
      top += clusterCore * 0.14;
      float heightFrac = clamp((p.y - bottom) / max(top - bottom, 0.001), 0.0, 1.0);
      float baseLift = smoothstep(0.0, 0.08, heightFrac);
      float crownFade = 1.0 - smoothstep(0.7, 1.0, heightFrac);
      float shoulder = smoothstep(0.1, 0.34, heightFrac) * (1.0 - smoothstep(0.56, 0.9, heightFrac));
      float heightGradient = baseLift * crownFade * mix(0.72, 1.0, shoulder + clusterCore * 0.2);

      if (heightGradient <= 0.0) return 0.0;

      vec3 samplePos = p;
      samplePos.y -= smoothstep(0.35, 0.95, cellMask) * 0.52;
      vec3 warpA = texture(uDetailNoise, fract(p * vec3(0.12, 0.07, 0.12) + vec3(0.0, 0.11, 0.0))).rgb - 0.5;
      vec3 warpB = texture(uShapeNoise, fract(p * vec3(0.095, 0.045, 0.095) - vec3(0.0, 0.07, 0.0))).rgb - 0.5;
      samplePos.xz += (warpA.xy * 0.24 + warpB.xy * 0.19);
      samplePos.y += warpB.z * 0.08;

      vec4 shapeSet = sampleShapeSet(samplePos, wind);
      vec4 detailSet = sampleDetailSet(samplePos, wind);
      float shape = sampleShape(shapeSet);
      float detail = sampleDetail(detailSet);
      float billow = pow(shapeSet.r, 1.35) * 0.16 + pow(shapeSet.g, 1.6) * 0.18;
      float columns = smoothstep(0.28, 0.86, towerMask) * smoothstep(0.08, 0.62, heightFrac) * 0.16;
      float shelf = shelfMask * smoothstep(0.12, 0.46, heightFrac) * (1.0 - smoothstep(0.55, 0.85, heightFrac)) * 0.14;
      float crown = pow(max(shapeSet.b - 0.24, 0.0), 1.8) * smoothstep(0.42, 0.92, heightFrac) * 0.18;
      float wisps = pow(max(detailSet.b - 0.48, 0.0), 2.0) * (1.0 - smoothstep(0.2, 0.72, heightFrac)) * 0.08;
      float edgeErosion = (1.0 - detail) * mix(0.16, 0.34, smoothstep(0.1, 0.95, heightFrac));
      edgeErosion += (1.0 - detailSet.a) * smoothstep(0.36, 0.98, heightFrac) * 0.18;
      edgeErosion += (1.0 - islandMask) * 0.24;

      float density = shape;
      density += coverage * 0.14;
      density += billow + columns + shelf + crown + wisps;
      density += islandMask * 0.16 + clusterCore * 0.12;
      density += cellMask * smoothstep(0.12, 0.78, heightFrac) * 0.14;
      density *= heightGradient * islandMask;
      density -= edgeErosion;
      density -= mix(0.45, 0.67, heightFrac);
      float lowerDensity = max(density * 1.9, 0.0);

      vec4 upperMacro = texture(uShapeNoise, fract((p + vec3(5.7, 1.3, 3.1)) * vec3(0.042, 0.018, 0.042) - wind * 0.12));
      float upperMask = smoothstep(0.42, 0.72, upperMacro.r) * smoothstep(0.3, 0.74, upperMacro.g);
      vec2 upperUv = p.xz * 0.19 - wind.xz * 0.14 + (upperMacro.ba - 0.5) * 0.28 + vec2(0.19, 0.41);
      vec2 upperCell = fract(upperUv) - 0.5;
      float upperEnvelope = 1.0 - smoothstep(0.24, 0.5, length(upperCell * vec2(0.92, 1.16)));
      float upperIsland = clamp(upperMask * (0.52 + upperEnvelope * 0.48), 0.0, 1.0);

      if (upperIsland <= 0.01) return lowerDensity;

      float upperBottom = 1.15 + upperMacro.b * 0.95;
      float upperTop = upperBottom + 1.6 + upperMacro.a * 1.95;
      float upperFrac = clamp((p.y - upperBottom) / max(upperTop - upperBottom, 0.001), 0.0, 1.0);
      float upperGradient = smoothstep(0.0, 0.08, upperFrac) * (1.0 - smoothstep(0.82, 1.0, upperFrac));

      if (upperGradient <= 0.0) return lowerDensity;

      vec3 upperPos = p + vec3(0.0, 0.12, 0.0);
      upperPos.xz += warpA.xy * 0.16 + warpB.xy * 0.1;
      vec4 upperShapeSet = sampleShapeSet(upperPos + vec3(3.1, 0.4, 2.2), wind * 0.9);
      vec4 upperDetailSet = sampleDetailSet(upperPos + vec3(1.4, 0.3, 4.1), wind * 0.86);
      float upperShape = sampleShape(upperShapeSet);
      float upperDetail = sampleDetail(upperDetailSet);
      float upperLobes = pow(upperShapeSet.g, 1.45) * 0.28 + pow(upperShapeSet.b, 1.8) * 0.22;
      float upperWisps = pow(max(upperDetailSet.b - 0.42, 0.0), 1.8) * 0.2;
      float upperDensity = upperShape * 1.04;
      upperDensity += upperLobes + upperWisps;
      upperDensity += upperIsland * 0.28;
      upperDensity *= upperGradient * upperIsland;
      upperDensity -= (1.0 - upperDetail) * 0.1;
      upperDensity -= mix(0.36, 0.56, upperFrac);

      vec4 topMacro = texture(uShapeNoise, fract((p + vec3(11.3, 4.7, 8.2)) * vec3(0.058, 0.024, 0.058) + wind * 0.08));
      float topMask = smoothstep(0.46, 0.74, topMacro.r) * smoothstep(0.3, 0.72, topMacro.g);
      float topBottom = 2.35 + topMacro.b * 0.95;
      float topTop = topBottom + 1.45 + topMacro.a * 1.75;
      float topFrac = clamp((p.y - topBottom) / max(topTop - topBottom, 0.001), 0.0, 1.0);
      float topGradient = smoothstep(0.0, 0.06, topFrac) * (1.0 - smoothstep(0.9, 1.0, topFrac));
      vec2 topUv = p.xz * 0.24 + (topMacro.ba - 0.5) * 0.22 + vec2(0.61, 0.27);
      float topEnvelope = 1.0 - smoothstep(0.24, 0.54, length((fract(topUv) - 0.5) * vec2(1.0, 1.18)));
      float topIsland = clamp(topMask * (0.46 + topEnvelope * 0.54), 0.0, 1.0);
      vec4 topShapeSet = sampleShapeSet(p + vec3(8.4, 2.1, 1.8), wind * 0.74);
      vec4 topDetailSet = sampleDetailSet(p + vec3(2.2, 1.6, 5.7), wind * 0.7);
      float topDensity = sampleShape(topShapeSet) * 0.84;
      topDensity += pow(topShapeSet.g, 1.6) * 0.2;
      topDensity += pow(max(topDetailSet.b - 0.42, 0.0), 1.8) * 0.16;
      topDensity += topIsland * 0.18;
      topDensity *= topGradient * topIsland;
      topDensity -= (1.0 - sampleDetail(topDetailSet)) * 0.09;
      topDensity -= mix(0.4, 0.58, topFrac);

      vec4 highMacro = texture(uShapeNoise, fract((p + vec3(17.2, 8.3, 12.1)) * vec3(0.074, 0.03, 0.074) - wind * 0.05));
      float highMask = smoothstep(0.44, 0.7, highMacro.r) * smoothstep(0.3, 0.68, highMacro.g);
      float highBottom = 3.95 + highMacro.b * 0.88;
      float highTop = highBottom + 1.15 + highMacro.a * 1.45;
      float highFrac = clamp((p.y - highBottom) / max(highTop - highBottom, 0.001), 0.0, 1.0);
      float highGradient = smoothstep(0.0, 0.05, highFrac) * (1.0 - smoothstep(0.92, 1.0, highFrac));
      vec2 highUv = p.xz * 0.29 + (highMacro.ba - 0.5) * 0.2 + vec2(0.13, 0.73);
      float highEnvelope = 1.0 - smoothstep(0.24, 0.56, length((fract(highUv) - 0.5) * vec2(1.04, 1.22)));
      float highIsland = clamp(highMask * (0.52 + highEnvelope * 0.48), 0.0, 1.0);
      vec4 highShapeSet = sampleShapeSet(p + vec3(15.7, 4.4, 6.8), wind * 0.62);
      vec4 highDetailSet = sampleDetailSet(p + vec3(4.8, 3.1, 9.6), wind * 0.6);
      float highDensity = sampleShape(highShapeSet) * 0.74;
      highDensity += pow(highShapeSet.g, 1.7) * 0.16;
      highDensity += pow(max(highDetailSet.b - 0.43, 0.0), 1.7) * 0.12;
      highDensity += highIsland * 0.16;
      highDensity *= highGradient * highIsland;
      highDensity -= (1.0 - sampleDetail(highDetailSet)) * 0.08;
      highDensity -= mix(0.42, 0.58, highFrac);

      return max(lowerDensity, max(max(upperDensity * 2.2, 0.0), max(max(topDensity * 1.95, 0.0), max(highDensity * 1.55, 0.0))));
    }

    vec2 uvToScene(vec2 uv) {
      return (uv * 2.0 - 1.0) * (uResolution.xy / min(uResolution.x, uResolution.y));
    }

    float ridge(float x, float center, float width, float height) {
      x = (x - center) / width;
      return exp(-x * x) * height;
    }

    float hash11(float p) {
      return fract(sin(p * 127.1) * 43758.5453123);
    }

    float noise1D(float x) {
      float i = floor(x);
      float f = fract(x);
      float u = f * f * (3.0 - 2.0 * f);
      return mix(hash11(i), hash11(i + 1.0), u);
    }

    void main() {
      float minRes = min(uResolution.x, uResolution.y);
      float pixelToScene = 2.0 / minRes;
      vec2 p = (gl_FragCoord.xy * 2.0 - uResolution.xy) / min(uResolution.x, uResolution.y);
      float sx = gl_FragCoord.x / uResolution.x * 2.0 - 1.0;
      float bottomPx = gl_FragCoord.y;
      vec2 follow = vec2(uPointer.x * 0.12, uPointer.y * 0.07);
      float time = uTime * 0.035;
      vec3 wind = vec3(time, 0.0, time * 0.32);
      vec2 sunPos = uvToScene(uSunUv);
      vec2 baseSunPos = uvToScene(uSunBaseUv);
      float sunX = clamp(uSunUv.x, 0.0, 1.0);
      float sunY = clamp(uSunUv.y, 0.0, 1.0);
      float dayAmount = smoothstep(0.14, 0.46, uSunBaseUv.y);
      float nightAmount = 1.0 - smoothstep(-0.08, 0.1, uSunBaseUv.y);
      float sunsetAmount = clamp(1.0 - dayAmount - nightAmount * 0.55, 0.0, 1.0);
      float horizonPx = mix(11.0, 15.5, 1.0 - abs(sx));
      horizonPx += ridge(sx, -0.96, 0.075, 1.8);
      horizonPx += ridge(sx, -0.48, 0.05, 1.2);
      horizonPx += ridge(sx, 0.05, 0.045, 2.1);
      horizonPx += ridge(sx, 0.62, 0.07, 1.4);
      horizonPx += pow(max(noise1D(sx * 4.6 + 1.2) - 0.46, 0.0) * 1.9, 2.5) * 1.8;
      horizonPx += pow(max(noise1D(sx * 14.0 + 5.4) - 0.5, 0.0) * 2.2, 3.2) * 0.9;
      horizonPx += pow(max(noise1D(sx * 52.0 + 11.1) - 0.48, 0.0) * 2.4, 4.2) * 0.45;
      horizonPx += pow(max(noise1D(sx * 135.0 + 19.4) - 0.52, 0.0) * 2.8, 5.0) * 0.3;
      horizonPx = min(horizonPx, 20.0);
      float horizonY = -uResolution.y / minRes + horizonPx * pixelToScene;

      vec3 skyTop = mix(vec3(0.03, 0.05, 0.1), vec3(0.46, 0.69, 0.96), dayAmount);
      skyTop = mix(skyTop, vec3(0.98, 0.96, 0.93), sunsetAmount);
      vec3 skyMid = mix(vec3(0.05, 0.08, 0.16), vec3(0.78, 0.88, 0.99), dayAmount);
      skyMid = mix(skyMid, vec3(0.99, 0.91, 0.78), sunsetAmount);
      vec3 skyBottom = mix(vec3(0.08, 0.1, 0.18), vec3(0.91, 0.96, 1.0), dayAmount);
      skyBottom = mix(skyBottom, vec3(0.98, 0.75, 0.48), sunsetAmount);
      vec3 color = mix(skyTop, skyMid, smoothstep(1.0, -0.05, p.y));
      color = mix(color, skyBottom, smoothstep(0.08, -1.0, p.y));
      vec3 backdropCoord = vec3(p.x * 0.28 + time * 0.3, p.y * 0.18 + 0.42, 0.17 + time * 0.06);
      vec4 backdropA = texture(uShapeNoise, fract(backdropCoord + vec3(0.0, 0.0, 0.13)));
      vec4 backdropB = texture(uShapeNoise, fract(backdropCoord * vec3(1.45, 1.2, 1.45) + vec3(0.37, 0.18, 0.49)));
      float upperBackdrop = smoothstep(0.46, 0.74, backdropA.r) * smoothstep(0.12, 1.08, p.y);
      upperBackdrop *= 1.0 - smoothstep(0.86, 1.42, p.y);
      upperBackdrop *= 0.66 + smoothstep(0.44, 0.8, backdropA.g) * 0.34;
      float upperBackdropDetail = smoothstep(0.46, 0.74, backdropB.b) * (1.0 - smoothstep(0.54, 0.82, backdropB.a));
      float highBackdrop = smoothstep(0.48, 0.76, backdropB.r) * smoothstep(0.74, 1.52, p.y) * (1.0 - smoothstep(1.28, 1.86, p.y));
      vec3 backdropColor = mix(vec3(0.74, 0.79, 0.89), vec3(1.0, 0.88, 0.76), sunsetAmount + dayAmount * 0.22);
      backdropColor = mix(backdropColor, vec3(0.2, 0.25, 0.36), nightAmount * 0.7);
      color = mix(color, backdropColor, upperBackdrop * 0.34 + upperBackdropDetail * upperBackdrop * 0.22 + highBackdrop * 0.18);
      color += mix(vec3(0.14, 0.18, 0.28), vec3(1.0, 0.77, 0.46), sunsetAmount + dayAmount * 0.5) *
        exp(-1.05 * length((p - sunPos) * vec2(0.72, 1.04))) * mix(0.08, 0.3, 1.0 - nightAmount * 0.6);

      float sunGlow = exp(-1.2 * length(p - sunPos));
      float sunHalo = exp(-3.8 * length(p - sunPos));
      float sunCore = exp(-7.2 * length(p - sunPos));
      color += mix(vec3(0.22, 0.28, 0.4), vec3(1.0, 0.84, 0.46), sunsetAmount + dayAmount * 0.45) * sunGlow * mix(0.04, 0.52, 1.0 - nightAmount);
      color += mix(vec3(0.12, 0.16, 0.28), vec3(1.0, 0.94, 0.76), sunsetAmount + dayAmount * 0.45) * sunHalo * mix(0.02, 0.28, 1.0 - nightAmount);
      color += mix(vec3(0.08, 0.1, 0.16), vec3(1.0, 0.78, 0.44), sunsetAmount) * sunCore * mix(0.0, 0.18, 1.0 - nightAmount);

      vec3 ro = vec3(follow.x * 0.2, 0.3 + follow.y * 0.08, -3.0);
      vec3 rd = normalize(vec3(p.x * 0.88, p.y * 0.72 + 0.06, 1.55));
      vec3 sunDir = normalize(vec3(
        mix(-0.95, 0.95, sunX),
        mix(-0.2, 0.92, sunY),
        -0.34
      ));
      float skyAboveHorizonPx = bottomPx - horizonPx;
      float horizonBand = smoothstep(1.5, 5.0, skyAboveHorizonPx) * (1.0 - smoothstep(12.0, 34.0, skyAboveHorizonPx));
      float earthMask = 1.0 - smoothstep(horizonPx - 0.35, horizonPx + 0.75, bottomPx);
      float rimMask = exp(-abs(bottomPx - horizonPx) * 2.2);

      if (horizonBand > 0.0) {
        vec3 shaftProbe = vec3(
          (p.x - sunPos.x) * 2.8,
          0.13 + clamp(skyAboveHorizonPx * pixelToScene * 0.5, 0.0, 0.14),
          2.9
        );
        float shaftDepth = 0.0;

        for (int k = 0; k < 3; k++) {
          shaftDepth += densityAt(shaftProbe + sunDir * float(k) * 0.42, wind) * 0.42;
        }

        float shaftLight = exp(-shaftDepth * 1.7);
        vec3 shaftWarm = mix(vec3(0.3, 0.16, 0.06), vec3(1.0, 0.71, 0.36), shaftLight);
        color += shaftWarm * horizonBand * 0.11;
        color *= 1.0 - horizonBand * (1.0 - shaftLight) * 0.14;
      }

      vec2 hit = intersectBox(ro, rd, vec3(-3.4, -1.8, -1.2), vec3(3.4, 7.2, 6.0));
      float transmittance = 1.0;
      vec3 cloudLight = vec3(0.0);

      if (hit.x < hit.y) {
        float startT = max(hit.x, 0.0);
        float endT = hit.y;
        float stepSize = (endT - startT) / 28.0;

        for (int i = 0; i < 28; i++) {
          float t = startT + stepSize * (float(i) + 0.5);
          if (t > endT) break;

          vec3 pos = ro + rd * t;
          float density = densityAt(pos, wind);

          if (density > 0.001) {
            float lightDepth = 0.0;

            for (int j = 0; j < 4; j++) {
              vec3 lightPos = pos + sunDir * (float(j) + 1.0) * 0.22;
              lightDepth += densityAt(lightPos, wind) * 0.22;
            }

            float beer = exp(-density * stepSize * 2.05);
            float alpha = 1.0 - beer;
            float lightTrans = exp(-lightDepth * 1.45);
            float powder = 1.0 - exp(-density * 2.8);
            float phase = phaseHG(0.42, dot(rd, sunDir));
            vec3 tintNoise = texture(
              uDetailNoise,
              fract(pos * vec3(0.16, 0.1, 0.16) + wind * 0.9 + vec3(0.0, 0.13, 0.07))
            ).rgb;
            float heightTint = clamp((pos.y - 0.2) / 2.2, 0.0, 1.0);
            float altitudeTint = smoothstep(1.4, 5.6, pos.y);
            float lightMix = clamp(lightTrans * 1.18 + powder * 0.16, 0.0, 1.0);
            float warmMix = clamp(0.32 + phase * 1.6 + tintNoise.g * 0.25 + heightTint * 0.2, 0.0, 1.0);
            float coolMix = clamp((1.0 - lightTrans) * 0.85 + tintNoise.b * 0.24 + density * 0.08, 0.0, 1.0);

            vec3 coolShadow = vec3(0.56, 0.6, 0.72);
            vec3 warmShadow = vec3(0.86, 0.64, 0.44);
            vec3 creamBody = vec3(0.99, 0.96, 0.9);
            vec3 peachBody = vec3(1.0, 0.88, 0.73);
            vec3 goldHighlight = vec3(1.0, 0.8, 0.48);
            vec3 hotHighlight = vec3(1.0, 0.93, 0.82);

            vec3 shadowColor = mix(coolShadow, warmShadow, warmMix);
            vec3 bodyColor = mix(creamBody, peachBody, clamp(tintNoise.r * 0.4 + heightTint * 0.35 + phase * 0.25, 0.0, 1.0));
            bodyColor = mix(bodyColor, vec3(0.92, 0.93, 0.98), coolMix * 0.18);
            shadowColor = mix(shadowColor, vec3(0.44, 0.48, 0.58), altitudeTint * 0.55);
            bodyColor = mix(bodyColor, vec3(0.78, 0.84, 0.94), altitudeTint * 0.34);

            vec3 sampleColor = mix(shadowColor, bodyColor, lightMix);
            sampleColor = mix(sampleColor, goldHighlight, clamp(powder * lightTrans * 0.34 + phase * 0.18, 0.0, 1.0));
            sampleColor = mix(sampleColor, hotHighlight, clamp(powder * lightTrans * 0.16 + tintNoise.g * 0.08, 0.0, 1.0));
            sampleColor += vec3(1.0, 0.72, 0.42) * phase * lightTrans * 0.24;
            sampleColor = mix(sampleColor, vec3(0.7, 0.77, 0.9), altitudeTint * (0.12 + (1.0 - lightTrans) * 0.18));
            sampleColor = mix(sampleColor, vec3(0.13, 0.17, 0.27) + vec3(0.06, 0.07, 0.1) * powder, nightAmount * 0.84);

            cloudLight += transmittance * sampleColor * alpha;
            transmittance *= beer;

            if (transmittance < 0.015) break;
          }
        }
      }

      color = color * transmittance + cloudLight;
      float landDepth = clamp((horizonPx - bottomPx) / max(horizonPx, 1.0), 0.0, 1.0);
      float sunScreenX = uSunUv.x * 2.0 - 1.0;
      float earthSun = exp(-abs(sx - sunScreenX) * 3.6);
      float earthShadow = 1.0 - earthSun;
      vec3 earthDark = vec3(0.19, 0.2, 0.22);
      vec3 earthLit = vec3(0.34, 0.35, 0.38);
      vec3 earthColor = mix(earthDark, earthLit, earthSun);
      earthColor *= mix(0.9, 1.02, smoothstep(0.0, 0.7, landDepth));
      earthColor += vec3(0.1, 0.11, 0.12) * exp(-landDepth * 13.0) * (0.04 + earthSun * 0.05);
      earthColor *= 0.9 + earthShadow * 0.08;
      vec3 rimColor = mix(vec3(0.56, 0.58, 0.64), vec3(1.0, 0.72, 0.34), earthSun);
      color = mix(color, earthColor, earthMask);
      color += rimColor * rimMask * (1.0 - earthMask * 0.82) * (0.04 + earthSun * 0.08);
      float citySeed = hash11(floor(gl_FragCoord.x * 0.85) + floor(landDepth * 26.0) * 97.0);
      float cityCluster = hash11(floor(gl_FragCoord.x * 0.08) * 19.0 + floor(landDepth * 9.0) * 11.0 + 7.0);
      float cityMask = step(0.9945, citySeed) * step(0.52, cityCluster);
      float cityFade = smoothstep(0.08, 0.52, landDepth) * (1.0 - smoothstep(0.82, 1.0, landDepth));
      vec3 cityColor = mix(vec3(1.0, 0.74, 0.42), vec3(0.74, 0.84, 1.0), hash11(floor(gl_FragCoord.x * 0.23) + 13.0));
      color += cityColor * cityMask * cityFade * earthMask * nightAmount * 0.95;
      color += vec3(0.08, 0.16, 0.28) * smoothstep(0.96, -0.84, p.y) * 0.028;

      fragColor = vec4(color, 1.0);
    }
  `,
});

scene.add(new THREE.Mesh(geometry, material));

function resize() {
  const width = Math.ceil(window.visualViewport?.width ?? window.innerWidth);
  const height = Math.ceil(window.visualViewport?.height ?? window.innerHeight);

  renderer.setSize(width, height, true);
  material.uniforms.uResolution.value.set(width, height);
}

resize();
window.addEventListener("resize", resize);

const targetPointer = new THREE.Vector2(0, 0);
const currentPointer = new THREE.Vector2(0, 0);
const currentSun = new THREE.Vector2();
const currentBaseSun = new THREE.Vector2();
const desiredSun = new THREE.Vector2();

function getAutoSunUv(target, elapsedTime) {
  const prefersDark = window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false;
  const phaseOffset = prefersDark ? Math.PI : 0;
  const angle = ((elapsedTime % 120) / 120) * Math.PI * 2 + phaseOffset;
  return target.set(
    0.5 - Math.cos(angle) * 0.82,
    0.08 + Math.sin(angle) * 0.82,
  );
}

function resetPointer() {
  targetPointer.set(0, 0);
}

function setTargetFromClient(clientX, clientY) {
  const width = window.visualViewport?.width ?? window.innerWidth;
  const height = window.visualViewport?.height ?? window.innerHeight;
  const x = THREE.MathUtils.clamp(clientX / width, 0, 1);
  const y = THREE.MathUtils.clamp(clientY / height, 0, 1);
  targetPointer.set(x * 2 - 1, (1 - y) * 2 - 1);
}

resetPointer();
getAutoSunUv(currentBaseSun, 0);
currentSun.copy(currentBaseSun);

window.addEventListener("pointermove", (event) => {
  setTargetFromClient(event.clientX, event.clientY);
});

window.addEventListener("pointerdown", (event) => {
  setTargetFromClient(event.clientX, event.clientY);
});

window.addEventListener("pointerup", (event) => {
  if (event.pointerType === "touch" || event.pointerType === "pen") {
    resetPointer();
  }
});

window.addEventListener("pointercancel", resetPointer);
window.addEventListener("touchend", resetPointer, { passive: true });
window.addEventListener("touchcancel", resetPointer, { passive: true });
window.addEventListener("blur", resetPointer);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    resetPointer();
  }
});
window.addEventListener("mouseout", (event) => {
  if (!event.relatedTarget) {
    resetPointer();
  }
});

const clock = new THREE.Clock();

function render() {
  const delta = clock.getDelta();
  const pointerEase = 1 - Math.exp(-delta * 5.5);
  const sunEase = 1 - Math.exp(-delta * 3.8);

  material.uniforms.uTime.value = clock.elapsedTime;
  currentPointer.lerp(targetPointer, pointerEase);
  getAutoSunUv(currentBaseSun, clock.elapsedTime);
  desiredSun.set(
    currentBaseSun.x + currentPointer.x * 0.18,
    currentBaseSun.y + currentPointer.y * 0.14,
  );
  currentSun.lerp(desiredSun, sunEase);
  material.uniforms.uPointer.value.copy(currentPointer);
  material.uniforms.uSunBaseUv.value.copy(currentBaseSun);
  material.uniforms.uSunUv.value.copy(currentSun);
  renderer.render(scene, camera);
  window.requestAnimationFrame(render);
}

render();
