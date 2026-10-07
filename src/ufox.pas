{ ============================================================================
  ufox.pas  --  отложенный конвейер в духе Fox Engine (Metal Gear Solid V)

  Порядок проходов повторяет разбор кадра MGS V (Adrian Courreges, 2017) и
  описание самой Kojima Productions с GDC 2013 "Photorealism Through the
  Eyes of a FOX":

    1. G-буфер            альбедо + прозрачность, нормаль + коэффициент
                          зависимости шероховатости от угла обзора,
                          шероховатость/металличность/отражательная
    2. карты теней        три каскада для солнца
    3. SSAO               ДВА разных алгоритма, результаты перемножаются --
                          так сделано и в Fox Engine
    4. освещение          сферические гармоники неба (аналог irradiance
                          spherical maps) + солнце по микрофасетной модели
    5. тонмаппинг СРАЗУ   дальше всё идёт уже в LDR, а исходная HDR-яркость
                          остаётся в альфа-канале -- этим приёмом Fox Engine
                          потом отбирает яркие пиксели для свечения
    6. bloom              яркий проход по альфе + четыре итерации размытия
                          Кавасэ (как в Fox Engine)
    7. FXAA               единственное сглаживание, доступное отложенному
                          рендеру того поколения

  Чего здесь нет по сравнению с оригиналом: отражений в экранном
  пространстве, глубины резкости, размытия в движении, объёмных облаков,
  подповерхностного рассеяния. Они перечислены в README.
  ============================================================================ }
unit ufox;

{$MODE OBJFPC}
{$H+}

interface

uses
  SysUtils, Math, umath, ugl, ugeom, ucamera, umesh;

const
  FOX_CASCADES   = 3;
  FOX_SHADOW_RES = 1024;

type
  TFoxTarget = record
    fbo     : GLuint;
    tex     : array[0..2] of GLuint;
    depthTex: GLuint;
    ncolor  : Integer;
    w, h    : Integer;
  end;

var
  { ---- параметры сцены ---- }
  fox_sun_dir     : TVec3;     { направление ОТ солнца (куда светит) }
  fox_sun_color   : TVec3;     { яркость солнца, линейное пространство }
  fox_sky_zenith  : TVec3;
  fox_sky_horizon : TVec3;
  fox_ground_color: TVec3;
  fox_fog_color   : TVec3;
  fox_fog_density : Single;
  fox_fog_height  : Single;
  fox_exposure    : Single;

  { ---- переключатели проходов ---- }
  fox_shadows   : Boolean = True;
  fox_ssao      : Boolean = True;
  fox_bloom     : Boolean = True;
  fox_fxaa      : Boolean = True;
  fox_bloom_thr : Single = 1.1;
  fox_bloom_mul : Single = 0.55;
  fox_ssao_radius: Single = 0.55;
  fox_ssao_power : Single = 1.3;

  { ---- статистика ---- }
  fox_w, fox_h  : Integer;
  { 1 -- вывести вместо кадра значение затенения от солнца }
  fox_debug_light: Single = 0.0;
  fox_verbose: Boolean = False;

function  fox_init(w, h: Integer): Boolean;
procedure fox_shutdown;

{ Пересчитать сферические гармоники неба. Вызывать после смены погоды. }
procedure fox_update_sky;

{ --- проход теней: вызывается до G-буфера --- }
procedure fox_shadow_setup(const cam: TCamera);
procedure fox_shadow_begin(cascade: Integer);
procedure fox_shadow_draw(var m: TMesh; const inst: array of TInstance;
                          count: Integer);
procedure fox_shadow_end;

{ --- G-буфер --- }
procedure fox_gbuffer_begin(const cam: TCamera);
procedure fox_draw(var m: TMesh; const inst: array of TInstance;
                   count: Integer);
procedure fox_gbuffer_end;

{ --- освещение и постобработка; результат уходит в указанный FBO --- }
procedure fox_resolve(targetFBO: GLuint);

{ Отладка: выложить на экран один из промежуточных буферов.
  0 альбедо, 1 нормали, 2 материал, 3 SSAO, 4 свечение. }
procedure fox_debug_blit(which: Integer; targetFBO: GLuint);

implementation

{ =========================================================================
  Шейдеры
  ========================================================================= }

const
  { ---------------- общий вершинный шейдер полноэкранного треугольника ---- }
  VS_FULL =
    '#version 330 core'                                              + #10 +
    'out vec2 vUV;'                                                  + #10 +
    'void main() {'                                                  + #10 +
    '  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);'      + #10 +
    '  vUV = p;'                                                     + #10 +
    '  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);'                 + #10 +
    '}' + #10;

  { ---------------- G-буфер ---------------- }
  VS_GBUF =
    '#version 330 core'                                              + #10 +
    'layout(location=0) in vec3 aPos;'                               + #10 +
    'layout(location=1) in vec3 aNrm;'                               + #10 +
    'layout(location=2) in vec2 aUV;'                                + #10 +
    'layout(location=3) in mat4 iModel;'                             + #10 +
    'layout(location=7) in vec4 iColor;'                             + #10 +
    'layout(location=8) in vec4 iMaterial;'                          + #10 +
    'uniform mat4 uViewProj;'                                        + #10 +
    'out vec3 vNrm;'                                                 + #10 +
    'out vec3 vPos;'                                                 + #10 +
    'out vec4 vCol;'                                                 + #10 +
    'out vec4 vMat;'                                                 + #10 +
    'void main() {'                                                  + #10 +
    '  vec4 wp = iModel * vec4(aPos, 1.0);'                          + #10 +
    '  vPos = wp.xyz;'                                               + #10 +
    '  vNrm = mat3(iModel) * aNrm;'                                  + #10 +
    '  vCol = iColor;'                                               + #10 +
    '  vMat = iMaterial;'                                            + #10 +
    '  gl_Position = uViewProj * wp;'                                + #10 +
    '}' + #10;

  FS_GBUF =
    '#version 330 core'                                              + #10 +
    'in vec3 vNrm; in vec3 vPos; in vec4 vCol; in vec4 vMat;'        + #10 +
    'layout(location=0) out vec4 oAlbedo;'                           + #10 +
    'layout(location=1) out vec4 oNormal;'                           + #10 +
    'layout(location=2) out vec4 oMaterial;'                         + #10 +
    '// процедурная сетка: сразу в альбедо, как обычная текстура'    + #10 +
    'float grid(vec2 uv) {'                                          + #10 +
    '  vec2 g = abs(fract(uv - 0.5) - 0.5) / fwidth(uv);'            + #10 +
    '  return mix(0.80, 1.0, min(min(g.x, g.y), 1.0));'              + #10 +
    '}'                                                              + #10 +
    'void main() {'                                                  + #10 +
    '  vec3 N = normalize(vNrm);'                                    + #10 +
    '  vec2 cuv = abs(N.y) > 0.5 ? vPos.xz'                          + #10 +
    '           : (abs(N.x) > 0.5 ? vPos.zy : vPos.xy);'             + #10 +
    '  oAlbedo   = vec4(vCol.rgb * grid(cuv), vCol.a);'              + #10 +
    '  oNormal   = vec4(N, vMat.w);'                                 + #10 +
    '  oMaterial = vec4(clamp(vMat.x, 0.03, 1.0), vMat.y, vMat.z, 1.0);' + #10 +
    '}' + #10;

  { ---------------- тени ---------------- }
  VS_SHADOW =
    '#version 330 core'                                              + #10 +
    'layout(location=0) in vec3 aPos;'                               + #10 +
    'layout(location=3) in mat4 iModel;'                             + #10 +
    'uniform mat4 uLightVP;'                                         + #10 +
    'void main() { gl_Position = uLightVP * (iModel * vec4(aPos,1.0)); }' + #10;

  FS_SHADOW =
    '#version 330 core'                                              + #10 +
    'void main() { }' + #10;

  { ---------------- SSAO: два алгоритма сразу ---------------- }
  FS_SSAO =
    '#version 330 core'                                              + #10 +
    'in vec2 vUV;'                                                   + #10 +
    'out vec4 oAO;'                                                  + #10 +
    'uniform sampler2D uDepth;'                                      + #10 +
    'uniform sampler2D uNormal;'                                     + #10 +
    'uniform mat4 uInvViewProj;'                                     + #10 +
    'uniform mat4 uViewProj;'                                        + #10 +
    'uniform vec3 uCamPos;'                                          + #10 +
    'uniform vec2 uNearFar;'                                         + #10 +
    'uniform vec2 uPixel;'                                           + #10 +
    'uniform float uRadius;'                                         + #10 +
    'uniform float uPower;'                                          + #10 +
    ''                                                               + #10 +
    'float linZ(float d) {'                                          + #10 +
    '  float n = uNearFar.x, f = uNearFar.y;'                        + #10 +
    '  float z = d * 2.0 - 1.0;'                                     + #10 +
    '  return (2.0 * n * f) / (f + n - z * (f - n));'                + #10 +
    '}'                                                              + #10 +
    'vec3 worldFrom(vec2 uv, float d) {'                             + #10 +
    '  vec4 c = uInvViewProj * vec4(uv * 2.0 - 1.0, d * 2.0 - 1.0, 1.0);' + #10 +
    '  return c.xyz / c.w;'                                          + #10 +
    '}'                                                              + #10 +
    'float hash(vec2 p) {'                                           + #10 +
    '  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);'  + #10 +
    '}'                                                              + #10 +
    'void main() {'                                                  + #10 +
    '  float d = texture(uDepth, vUV).r;'                            + #10 +
    '  if (d >= 0.9999) { oAO = vec4(1.0); return; }'                + #10 +
    '  vec3 P = worldFrom(vUV, d);'                                  + #10 +
    '  vec3 N = normalize(texture(uNormal, vUV).xyz);'               + #10 +
    '  float z0 = linZ(d);'                                          + #10 +
    '  float rnd = hash(gl_FragCoord.xy) * 6.2831853;'               + #10 +
    ''                                                               + #10 +
    '  // --- 1. полусферическое SSAO: честная выборка вокруг нормали ---' + #10 +
    '  vec3 T = normalize(abs(N.y) < 0.9 ? cross(vec3(0,1,0), N)'    + #10 +
    '                                     : cross(vec3(1,0,0), N));' + #10 +
    '  vec3 B = cross(N, T);'                                        + #10 +
    '  float occ = 0.0;'                                             + #10 +
    '  const int NS = 10;'                                           + #10 +
    '  for (int i = 0; i < NS; ++i) {'                               + #10 +
    '    float a = rnd + float(i) * 2.3999632;'                      + #10 +
    '    float r = sqrt((float(i) + 0.5) / float(NS));'              + #10 +
    '    vec3 dir = normalize(T * cos(a) * r + B * sin(a) * r'       + #10 +
    '                         + N * sqrt(1.0 - r * r));'             + #10 +
    '    vec3 sp = P + dir * uRadius * (0.35 + 0.65 * r);'           + #10 +
    '    vec4 cp = uViewProj * vec4(sp, 1.0);'                       + #10 +
    '    vec2 suv = cp.xy / cp.w * 0.5 + 0.5;'                       + #10 +
    '    if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) continue;' + #10 +
    '    float sz = linZ(texture(uDepth, suv).r);'                   + #10 +
    '    float spz = linZ(cp.z / cp.w * 0.5 + 0.5);'                 + #10 +
    '    if (sz < spz - 0.02) {'                                     + #10 +
    '      occ += smoothstep(0.0, 1.0, uRadius / max(abs(z0 - sz), 1e-4));' + #10 +
    '    }'                                                          + #10 +
    '  }'                                                            + #10 +
    '  float aoA = 1.0 - clamp(occ / float(NS), 0.0, 1.0);'          + #10 +
    ''                                                               + #10 +
    '  // --- 2. линейное интегральное SSAO: две симметричные пары,' + #10 +
    '  //        всего пять выборок глубины. Так делает Fox Engine.' + #10 +
    '  float px = uRadius / max(z0, 0.3);'                           + #10 +
    '  float aoB = 0.0;'                                             + #10 +
    '  for (int k = 0; k < 2; ++k) {'                                + #10 +
    '    float a = rnd + float(k) * 1.5707963;'                      + #10 +
    '    vec2 off = vec2(cos(a), sin(a)) * uPixel * px * 40.0;'      + #10 +
    '    float za = linZ(texture(uDepth, vUV + off).r);'             + #10 +
    '    float zb = linZ(texture(uDepth, vUV - off).r);'             + #10 +
    '    // центр дальше обоих соседей -- это вогнутость'            + #10 +
    '    float c = (2.0 * z0 - za - zb);'                            + #10 +
    '    if (abs(z0 - za) < uRadius * 2.0 && abs(z0 - zb) < uRadius * 2.0)' + #10 +
    '      aoB += clamp(c / (uRadius * 0.9), 0.0, 1.0);'             + #10 +
    '  }'                                                            + #10 +
    '  aoB = 1.0 - clamp(aoB * 0.5, 0.0, 1.0);'                      + #10 +
    ''                                                               + #10 +
    '  float ao = pow(clamp(aoA * aoB, 0.0, 1.0), uPower);'          + #10 +
    '  oAO = vec4(ao, ao, ao, 1.0);'                                 + #10 +
    '}' + #10;

  { билатеральное размытие SSAO: сглаживает шум, но держит края }
  FS_AOBLUR =
    '#version 330 core'                                              + #10 +
    'in vec2 vUV; out vec4 oAO;'                                     + #10 +
    'uniform sampler2D uAO;'                                         + #10 +
    'uniform sampler2D uDepth;'                                      + #10 +
    'uniform vec2 uPixel;'                                           + #10 +
    'void main() {'                                                  + #10 +
    '  float d0 = texture(uDepth, vUV).r;'                           + #10 +
    '  float sum = 0.0, wsum = 0.0;'                                 + #10 +
    '  for (int y = -2; y <= 2; ++y)'                                + #10 +
    '  for (int x = -2; x <= 2; ++x) {'                              + #10 +
    '    vec2 uv = vUV + vec2(x, y) * uPixel;'                       + #10 +
    '    float d = texture(uDepth, uv).r;'                           + #10 +
    '    float w = exp(-abs(d - d0) * 900.0);'                       + #10 +
    '    sum += texture(uAO, uv).r * w;'                             + #10 +
    '    wsum += w;'                                                 + #10 +
    '  }'                                                            + #10 +
    '  float ao = wsum > 0.0 ? sum / wsum : 1.0;'                    + #10 +
    '  oAO = vec4(ao, ao, ao, 1.0);'                                 + #10 +
    '}' + #10;

  { ---------------- освещение ---------------- }
  FS_LIGHT =
    '#version 330 core'                                              + #10 +
    'in vec2 vUV;'                                                   + #10 +
    'out vec4 oColor;'                                               + #10 +
    'uniform sampler2D uAlbedo, uNormal, uMaterial, uDepth, uAO;'    + #10 +
    'uniform sampler2D uShadow0, uShadow1, uShadow2;'                + #10 +
    'uniform mat4 uInvViewProj;'                                     + #10 +
    'uniform mat4 uLightVP0, uLightVP1, uLightVP2;'                  + #10 +
    'uniform vec3 uCamPos, uSunDir, uSunColor;'                      + #10 +
    'uniform vec3 uSH[9];'                                           + #10 +
    'uniform vec3 uSkyZenith, uSkyHorizon, uGround, uFogColor;'      + #10 +
    'uniform vec3 uCascadeSplits;'                                   + #10 +
    'uniform vec2 uFog;'       { плотность, высота }                 + #10 +
    'uniform float uExposure;'                                       + #10 +
    'uniform float uShadowOn;'                                       + #10 +
    'uniform float uAOOn;'                                           + #10 +
    'uniform float uDebug;'                                          + #10 +
    'const float PI = 3.14159265;'                                   + #10 +
    'vec3 gDbg = vec3(1.0, 0.0, 1.0);'                               + #10 +
    ''                                                               + #10 +
    '// Облучённость из сферических гармоник второго порядка.'       + #10 +
    '// В Fox Engine это "irradiance spherical maps": окружение'     + #10 +
    '// сцены пакуется в коэффициенты SH и читается на лету.'        + #10 +
    'vec3 shIrradiance(vec3 n) {'                                    + #10 +
    '  const float A0 = 3.141593, A1 = 2.094395, A2 = 0.785398;'     + #10 +
    '  vec3 e = A0 * 0.282095 * uSH[0];'                             + #10 +
    '  e += A1 * 0.488603 * (uSH[1] * n.y + uSH[2] * n.z + uSH[3] * n.x);' + #10 +
    '  e += A2 * 1.092548 * (uSH[4] * n.x * n.y + uSH[5] * n.y * n.z' + #10 +
    '                        + uSH[7] * n.x * n.z);'                 + #10 +
    '  e += A2 * 0.315392 * uSH[6] * (3.0 * n.z * n.z - 1.0);'       + #10 +
    '  e += A2 * 0.546274 * uSH[8] * (n.x * n.x - n.y * n.y);'       + #10 +
    '  return max(e, vec3(0.0));'                                    + #10 +
    '}'                                                              + #10 +
    ''                                                               + #10 +
    'vec3 skyColor(vec3 d) {'                                        + #10 +
    '  float h = clamp(d.y * 0.5 + 0.5, 0.0, 1.0);'                  + #10 +
    '  vec3 c = mix(uGround, uSkyHorizon, smoothstep(0.42, 0.52, h));' + #10 +
    '  c = mix(c, uSkyZenith, smoothstep(0.5, 1.0, h));'             + #10 +
    '  float sd = max(dot(d, -uSunDir), 0.0);'                       + #10 +
    '  c += uSunColor * pow(sd, 1200.0) * 60.0;'          { диск }   + #10 +
    '  c += uSunColor * pow(sd, 8.0) * 0.18;'             { ореол }  + #10 +
    '  return c;'                                                    + #10 +
    '}'                                                              + #10 +
    ''                                                               + #10 +
    'float distGGX(float NoH, float a) {'                            + #10 +
    '  float a2 = a * a;'                                            + #10 +
    '  float d = NoH * NoH * (a2 - 1.0) + 1.0;'                      + #10 +
    '  return a2 / max(PI * d * d, 1e-7);'                           + #10 +
    '}'                                                              + #10 +
    'float visSmith(float NoV, float NoL, float a) {'                + #10 +
    '  float k = a * 0.5;'                                           + #10 +
    '  float gv = NoL * (NoV * (1.0 - k) + k);'                      + #10 +
    '  float gl = NoV * (NoL * (1.0 - k) + k);'                      + #10 +
    '  return 0.5 / max(gv + gl, 1e-6);'                             + #10 +
    '}'                                                              + #10 +
    'vec3 fresnel(vec3 f0, float u) {'                               + #10 +
    '  return f0 + (vec3(1.0) - f0) * pow(1.0 - u, 5.0);'            + #10 +
    '}'                                                              + #10 +
    '// аналитическая аппроксимация интеграла окружения (Karis)'     + #10 +
    'vec3 envBRDF(vec3 f0, float rough, float NoV) {'                + #10 +
    '  const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);'          + #10 +
    '  const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);'              + #10 +
    '  vec4 r = vec4(rough, rough, rough, rough) * c0 + c1;'         + #10 +
    '  float a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;'  + #10 +
    '  vec2 ab = vec2(-1.04, 1.04) * a004 + r.zw;'                   + #10 +
    '  return f0 * ab.x + ab.y;'                                     + #10 +
    '}'                                                              + #10 +
    ''                                                               + #10 +
    'float sampleCascade(sampler2D sm, mat4 lvp, vec3 P, float bias) {' + #10 +
    '  vec4 lc = lvp * vec4(P, 1.0);'                                + #10 +
    '  vec3 pc = lc.xyz / lc.w * 0.5 + 0.5;'                         + #10 +

    '  if (pc.x < 0.001 || pc.x > 0.999 || pc.y < 0.001 || pc.y > 0.999' + #10 +
    '      || pc.z > 1.0) return 1.0;'                               + #10 +
    '  float s = 0.0;'                                               + #10 +
    '  float t = 1.0 / 1024.0;'                                      + #10 +
    '  for (int y = -1; y <= 1; ++y)'                                + #10 +
    '  for (int x = -1; x <= 1; ++x) {'                              + #10 +
    '    float d = texture(sm, pc.xy + vec2(x, y) * t).r;'           + #10 +
    '    s += (pc.z - bias > d) ? 0.0 : 1.0;'                        + #10 +
    '  }'                                                            + #10 +
    '  return s / 9.0;'                                              + #10 +
    '}'                                                              + #10 +
    ''                                                               + #10 +
    'void main() {'                                                  + #10 +
    '  float d = texture(uDepth, vUV).r;'                            + #10 +
    '  vec4 c = uInvViewProj * vec4(vUV * 2.0 - 1.0, d * 2.0 - 1.0, 1.0);' + #10 +
    '  vec3 P = c.xyz / c.w;'                                        + #10 +
    '  vec3 V = normalize(uCamPos - P);'                             + #10 +
    '  vec3 hdr;'                                                    + #10 +
    ''                                                               + #10 +
    '  if (d >= 0.9999) {'                                           + #10 +
    '    hdr = skyColor(normalize(-V));'                             + #10 +
    '  } else {'                                                     + #10 +
    '    vec4 alb = texture(uAlbedo, vUV);'                          + #10 +
    '    vec4 nrm = texture(uNormal, vUV);'                          + #10 +
    '    vec4 mat = texture(uMaterial, vUV);'                        + #10 +
    '    vec3 N = normalize(nrm.xyz);'                               + #10 +
    '    float NoV = clamp(dot(N, V), 1e-4, 1.0);'                   + #10 +
    ''                                                               + #10 +
    '    // Шероховатость, зависящая от угла обзора: на скользящих'  + #10 +
    '    // углах поверхность выглядит глаже и отражает сильнее.'    + #10 +
    '    // Фирменная черта Fox Engine.'                             + #10 +
    '    float rough = mat.r;'                                       + #10 +
    '    rough = mix(rough, rough * 0.25, nrm.w * pow(1.0 - NoV, 3.0));' + #10 +
    '    rough = clamp(rough, 0.03, 1.0);'                           + #10 +
    '    float a = rough * rough;'                                   + #10 +
    '    float metal = mat.g;'                                       + #10 +
    '    vec3 f0 = mix(vec3(0.04 + 0.12 * mat.b), alb.rgb, metal);'  + #10 +
    '    vec3 diffCol = alb.rgb * (1.0 - metal);'                    + #10 +
    ''                                                               + #10 +
    '    // --- солнце ---'                                          + #10 +
    '    vec3 L = normalize(-uSunDir);'                              + #10 +
    '    float NoL = max(dot(N, L), 0.0);'                           + #10 +
    '    vec3 H = normalize(L + V);'                                 + #10 +
    '    float NoH = max(dot(N, H), 0.0);'                           + #10 +
    '    float VoH = max(dot(V, H), 0.0);'                           + #10 +
    '    vec3 spec = fresnel(f0, VoH) * distGGX(NoH, a)'             + #10 +
    '                * visSmith(NoV, NoL, a);'                       + #10 +
    ''                                                               + #10 +
    '    float sh = 1.0;'                                            + #10 +
    '    if (uShadowOn > 0.5 && NoL > 0.0) {'                        + #10 +
    '      float vd = length(uCamPos - P);'                          + #10 +
    '      float bias = 0.0012 + 0.004 * (1.0 - NoL);'               + #10 +
    '      if (vd < uCascadeSplits.x) {'                            + #10 +
    '        sh = sampleCascade(uShadow0, uLightVP0, P, bias);'      + #10 +
    '      } else if (vd < uCascadeSplits.y) {'                      + #10 +
    '        sh = sampleCascade(uShadow1, uLightVP1, P, bias * 2.0);' + #10 +
    '      } else {'                                                 + #10 +
    '        sh = sampleCascade(uShadow2, uLightVP2, P, bias * 4.0);' + #10 +
    '      }'                                                        + #10 +
    '      gDbg = vec3(sh);'                                         + #10 +
    '    }'                                                          + #10 +
    ''                                                               + #10 +

    '    vec3 direct = (diffCol / PI + spec) * uSunColor * NoL * sh;' + #10 +
    ''                                                               + #10 +
    '    // --- небо: диффузная часть из гармоник, зеркальная из'    + #10 +
    '    //     аналитического неба вдоль отражённого луча ---'      + #10 +
    '    float ao = uAOOn > 0.5 ? texture(uAO, vUV).r : 1.0;'        + #10 +
    '    vec3 irr = shIrradiance(N);'                                + #10 +
    '    vec3 ambDiff = diffCol * irr / PI * ao;'                    + #10 +
    '    vec3 R = reflect(-V, N);'                                   + #10 +
    '    vec3 envSpec = mix(skyColor(R), irr / PI, rough);'          + #10 +
    '    // горизонтальное затенение: отражение не должно светить'   + #10 +
    '    // из-под поверхности'                                      + #10 +
    '    float horiz = clamp(1.0 + dot(R, N), 0.0, 1.0);'            + #10 +
    '    vec3 ambSpec = envSpec * envBRDF(f0, rough, NoV)'           + #10 +
    '                   * horiz * horiz * mix(ao, 1.0, 0.5);'        + #10 +
    ''                                                               + #10 +
    '    hdr = direct + ambDiff + ambSpec;'                          + #10 +
    ''                                                               + #10 +
    '    // --- воздушная перспектива: плотность падает с высотой ---' + #10 +
    '    float dist = length(uCamPos - P);'                          + #10 +
    '    float hRef = exp(-max(P.y, 0.0) / max(uFog.y, 0.01));'      + #10 +
    '    float f = 1.0 - exp(-dist * uFog.x * hRef);'                + #10 +
    '    float sunAmount = max(dot(normalize(P - uCamPos), -uSunDir), 0.0);' + #10 +
    '    vec3 fogc = mix(uFogColor, uSunColor * 0.9,'                + #10 +
    '                    pow(sunAmount, 6.0) * 0.6);'                + #10 +
    '    hdr = mix(hdr, fogc, clamp(f, 0.0, 1.0));'                  + #10 +
    '  }'                                                            + #10 +
    ''                                                               + #10 +
    '  // Тонмаппинг выполняется СРАЗУ, дальше конвейер идёт в LDR,' + #10 +
    '  // а исходная HDR-яркость остаётся в альфе: по ней потом'     + #10 +
    '  // отбираются яркие пиксели для свечения. Приём Fox Engine.'  + #10 +
    '  if (uDebug > 0.5) { oColor = vec4(gDbg, 1.0); return; }'       + #10 +
    '  vec3 x = hdr * uExposure;'                                    + #10 +
    '  float lum = dot(hdr, vec3(0.2126, 0.7152, 0.0722)) * uExposure;' + #10 +
    '  // фильмическая кривая (аппроксимация ACES, Narkowicz)'       + #10 +
    '  vec3 t = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);' + #10 +
    '  t = clamp(t, 0.0, 1.0);'                                      + #10 +
    '  oColor = vec4(pow(t, vec3(1.0 / 2.2)), lum);'                 + #10 +
    '}' + #10;

  { ---------------- свечение ---------------- }
  FS_BRIGHT =
    '#version 330 core'                                              + #10 +
    'in vec2 vUV; out vec4 oColor;'                                  + #10 +
    'uniform sampler2D uScene;'                                      + #10 +
    'uniform float uThreshold;'                                      + #10 +
    'void main() {'                                                  + #10 +
    '  vec4 s = texture(uScene, vUV);'                               + #10 +
    '  // Яркость берём из альфы -- это ИСХОДНАЯ HDR-яркость до'     + #10 +
    '  // тонмаппинга. После тонмаппинга по цвету её уже не узнать.' + #10 +
    '  float w = smoothstep(uThreshold, uThreshold * 2.0, s.a);'     + #10 +
    '  oColor = vec4(s.rgb * w, 1.0);'                               + #10 +
    '}' + #10;

  { Размытие Кавасэ: четыре прохода дают радиус как у гауссова,
    но выборок втрое меньше. Именно его использует Fox Engine. }
  FS_KAWASE =
    '#version 330 core'                                              + #10 +
    'in vec2 vUV; out vec4 oColor;'                                  + #10 +
    'uniform sampler2D uTex;'                                        + #10 +
    'uniform vec2 uPixel;'                                           + #10 +
    'uniform float uOffset;'                                         + #10 +
    'void main() {'                                                  + #10 +
    '  vec2 o = uPixel * (uOffset + 0.5);'                           + #10 +
    '  vec3 c = texture(uTex, vUV + vec2( o.x,  o.y)).rgb;'          + #10 +
    '  c += texture(uTex, vUV + vec2(-o.x,  o.y)).rgb;'              + #10 +
    '  c += texture(uTex, vUV + vec2( o.x, -o.y)).rgb;'              + #10 +
    '  c += texture(uTex, vUV + vec2(-o.x, -o.y)).rgb;'              + #10 +
    '  oColor = vec4(c * 0.25, 1.0);'                                + #10 +
    '}' + #10;

  FS_COMPOSITE =
    '#version 330 core'                                              + #10 +
    'in vec2 vUV; out vec4 oColor;'                                  + #10 +
    'uniform sampler2D uScene, uBloom;'                              + #10 +
    'uniform float uBloomMul;'                                       + #10 +
    'uniform float uBloomOn;'                                        + #10 +
    'void main() {'                                                  + #10 +
    '  vec4 s = texture(uScene, vUV);'                               + #10 +
    '  vec3 c = s.rgb;'                                              + #10 +
    '  if (uBloomOn > 0.5) c += texture(uBloom, vUV).rgb * uBloomMul;' + #10 +
    '  // лёгкое виньетирование -- оно есть и в кадрах MGS V'        + #10 +
    '  vec2 q = vUV - 0.5;'                                          + #10 +
    '  c *= 1.0 - dot(q, q) * 0.35;'                                 + #10 +
    '  oColor = vec4(c, s.a);'                                       + #10 +
    '}' + #10;

  { ---------------- FXAA ---------------- }
  FS_FXAA =
    '#version 330 core'                                              + #10 +
    'in vec2 vUV; out vec4 oColor;'                                  + #10 +
    'uniform sampler2D uTex;'                                        + #10 +
    'uniform vec2 uPixel;'                                           + #10 +
    'uniform float uOn;'                                             + #10 +
    'float lum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }' + #10 +
    'void main() {'                                                  + #10 +
    '  vec3 cM = texture(uTex, vUV).rgb;'                            + #10 +
    '  if (uOn < 0.5) { oColor = vec4(cM, 1.0); return; }'           + #10 +
    '  float lNW = lum(texture(uTex, vUV + vec2(-1,-1) * uPixel).rgb);' + #10 +
    '  float lNE = lum(texture(uTex, vUV + vec2( 1,-1) * uPixel).rgb);' + #10 +
    '  float lSW = lum(texture(uTex, vUV + vec2(-1, 1) * uPixel).rgb);' + #10 +
    '  float lSE = lum(texture(uTex, vUV + vec2( 1, 1) * uPixel).rgb);' + #10 +
    '  float lM  = lum(cM);'                                         + #10 +
    '  float lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));'     + #10 +
    '  float lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));'     + #10 +
    '  if (lMax - lMin < max(0.0312, lMax * 0.125)) {'               + #10 +
    '    oColor = vec4(cM, 1.0); return;'                            + #10 +
    '  }'                                                            + #10 +
    '  vec2 dir = vec2(-((lNW + lNE) - (lSW + lSE)),'                + #10 +
    '                   ((lNW + lSW) - (lNE + lSE)));'               + #10 +
    '  float red = max((lNW + lNE + lSW + lSE) * 0.25 * 0.125, 1.0/128.0);' + #10 +
    '  float rcp = 1.0 / (min(abs(dir.x), abs(dir.y)) + red);'       + #10 +
    '  dir = clamp(dir * rcp, vec2(-8.0), vec2(8.0)) * uPixel;'      + #10 +
    '  vec3 rA = 0.5 * (texture(uTex, vUV + dir * (1.0/3.0 - 0.5)).rgb' + #10 +
    '                 + texture(uTex, vUV + dir * (2.0/3.0 - 0.5)).rgb);' + #10 +
    '  vec3 rB = rA * 0.5 + 0.25 * (texture(uTex, vUV - dir * 0.5).rgb' + #10 +
    '                 + texture(uTex, vUV + dir * 0.5).rgb);'        + #10 +
    '  float lB = lum(rB);'                                          + #10 +
    '  oColor = vec4((lB < lMin || lB > lMax) ? rA : rB, 1.0);'      + #10 +
    '}' + #10;

  FS_BLIT =
    '#version 330 core'                                              + #10 +
    'in vec2 vUV; out vec4 oColor;'                                  + #10 +
    'uniform sampler2D uTex;'                                        + #10 +
    'uniform float uScale;'                                          + #10 +
    'uniform float uBias;'                                           + #10 +
    'void main() { oColor = vec4(texture(uTex, vUV).rgb * uScale + uBias, 1.0); }' + #10;

{ =========================================================================
  Состояние модуля
  ========================================================================= }

type
  TProg = record
    id: GLuint;
  end;

var
  g_gbuf, g_scene, g_ao, g_aoblur, g_bright, g_blurA, g_blurB: TFoxTarget;
  g_shadow: array[0..FOX_CASCADES - 1] of TFoxTarget;
  g_lightVP: array[0..FOX_CASCADES - 1] of TMat4;
  g_splits: TVec3;
  g_cam: TCamera;
  g_quadVAO: GLuint = 0;

  p_gbuf, p_shadow, p_ssao, p_aoblur, p_light, p_bright, p_kawase,
  p_comp, p_fxaa, p_blit: GLuint;

  g_sh: TSH9;

{ --------------------------------------------------------------- утилиты }

function compile(kind: GLenum; const src: string): GLuint;
var
  status, loglen: GLint;
  log: array[0..4095] of Char;
  p: PChar;
begin
  Result := glCreateShader(kind);
  p := PChar(src);
  glShaderSource(Result, 1, @p, nil);
  glCompileShader(Result);
  glGetShaderiv(Result, GL_COMPILE_STATUS, @status);
  if status = GL_FALSE then
  begin
    glGetShaderInfoLog(Result, SizeOf(log), @loglen, @log[0]);
    WriteLn('[fox] ошибка компиляции шейдера:');
    WriteLn(PChar(@log[0]));
    glDeleteShader(Result);
    Result := 0;
  end;
end;

function link_prog(const vs, fs: string): GLuint;
var
  v, f: GLuint;
  status, loglen: GLint;
  log: array[0..4095] of Char;
begin
  Result := 0;
  v := compile(GL_VERTEX_SHADER, vs);
  if v = 0 then Exit;
  f := compile(GL_FRAGMENT_SHADER, fs);
  if f = 0 then
  begin
    glDeleteShader(v);
    Exit;
  end;
  Result := glCreateProgram();
  glAttachShader(Result, v);
  glAttachShader(Result, f);
  glLinkProgram(Result);
  glGetProgramiv(Result, GL_LINK_STATUS, @status);
  if status = GL_FALSE then
  begin
    glGetProgramInfoLog(Result, SizeOf(log), @loglen, @log[0]);
    WriteLn('[fox] ошибка компоновки программы:');
    WriteLn(PChar(@log[0]));
    glDeleteProgram(Result);
    Result := 0;
  end;
  glDeleteShader(v);
  glDeleteShader(f);
end;

procedure set1f(p: GLuint; const n: string; v: Single); inline;
begin
  glUniform1f(glGetUniformLocation(p, PChar(n)), v);
end;

procedure set2f(p: GLuint; const n: string; a, b: Single); inline;
begin
  glUniform2f(glGetUniformLocation(p, PChar(n)), a, b);
end;

procedure set3v(p: GLuint; const n: string; const v: TVec3); inline;
begin
  glUniform3f(glGetUniformLocation(p, PChar(n)), v.x, v.y, v.z);
end;

procedure setm4(p: GLuint; const n: string; const m: TMat4); inline;
begin
  glUniformMatrix4fv(glGetUniformLocation(p, PChar(n)), 1, GL_FALSE, @m.m[0]);
end;

procedure bind_tex(p: GLuint; const n: string; unit_: Integer; tex: GLuint);
begin
  glActiveTexture(GL_TEXTURE0 + unit_);
  glBindTexture(GL_TEXTURE_2D, tex);
  glUniform1i(glGetUniformLocation(p, PChar(n)), unit_);
end;

function make_tex(w, h: Integer; internal, fmt, typ: GLenum;
                  filter: GLenum): GLuint;
begin
  glGenTextures(1, @Result);
  glBindTexture(GL_TEXTURE_2D, Result);
  glTexImage2D(GL_TEXTURE_2D, 0, internal, w, h, 0, fmt, typ, nil);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
end;

function make_target(w, h, ncolor: Integer; hdr, withDepth, depthOnly: Boolean): TFoxTarget;
var
  i: Integer;
  bufs: array[0..2] of GLenum;
  status: GLenum;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.w := w;
  Result.h := h;
  Result.ncolor := ncolor;
  glGenFramebuffers(1, @Result.fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, Result.fbo);

  for i := 0 to ncolor - 1 do
  begin
    if hdr then
      Result.tex[i] := make_tex(w, h, GL_RGBA16F, GL_RGBA, GL_FLOAT, GL_LINEAR)
    else
      Result.tex[i] := make_tex(w, h, GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, GL_LINEAR);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + i,
                           GL_TEXTURE_2D, Result.tex[i], 0);
    bufs[i] := GL_COLOR_ATTACHMENT0 + i;
  end;

  if ncolor > 0 then
    glDrawBuffers(ncolor, @bufs[0])
  else
  begin
    bufs[0] := 0;                      { GL_NONE }
    glDrawBuffers(1, @bufs[0]);
  end;

  if withDepth then
  begin
    Result.depthTex := make_tex(w, h, GL_DEPTH_COMPONENT24, GL_DEPTH_COMPONENT,
                                GL_FLOAT, GL_NEAREST);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                           GL_TEXTURE_2D, Result.depthTex, 0);
  end;

  status := glCheckFramebufferStatus(GL_FRAMEBUFFER);
  if status <> GL_FRAMEBUFFER_COMPLETE then
    WriteLn(Format('[fox] цель %dx%d неполна, код $%x', [w, h, status]));
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  if depthOnly then ;
end;

procedure draw_fullscreen;
begin
  glBindVertexArray(g_quadVAO);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glBindVertexArray(0);
end;

{ =========================================================================
  Небо в сферических гармониках

  Интегрируем процедурное небо по сфере и раскладываем по базису второго
  порядка. Девять цветов целиком описывают мягкую засветку от окружения --
  именно это в Fox Engine называется irradiance spherical map.
  ========================================================================= }

function sky_sample(const d: TVec3): TVec3;
var
  h, sd: Single;
  c: TVec3;
begin
  h := fclamp(d.y * 0.5 + 0.5, 0, 1);
  c := v3_lerp(fox_ground_color, fox_sky_horizon,
               fclamp((h - 0.42) / 0.10, 0, 1));
  c := v3_lerp(c, fox_sky_zenith, fclamp((h - 0.5) / 0.5, 0, 1));
  sd := fmax(v3_dot(d, v3_neg(fox_sun_dir)), 0);
  c := v3_add(c, v3_mul(fox_sun_color, Power(sd, 8.0) * 0.18));
  Result := c;
end;

procedure fox_update_sky;
const
  NSAMP = 2048;
var
  i, k: Integer;
  u1, z, r, phi: Single;
  d: TVec3;
begin
  sh_clear(g_sh);

  for i := 0 to NSAMP - 1 do
  begin
    { равномерная выборка сферы по спирали -- без случайных чисел,
      значит результат воспроизводим от запуска к запуску }
    u1 := (i + 0.5) / NSAMP;
    z := 1.0 - 2.0 * u1;
    r := Sqrt(fmax(0.0, 1.0 - z * z));
    phi := i * 2.39996323;
    d := v3(r * Cos(phi), z, r * Sin(phi));

    sh_add(g_sh, d, sky_sample(d), 1.0);
  end;

  { нормировка Монте-Карло: 4*pi / N }
  for k := 0 to 8 do
    g_sh[k] := v3_mul(g_sh[k], 4.0 * PI_F / NSAMP);
end;

{ =========================================================================
  Инициализация
  ========================================================================= }

function fox_init(w, h: Integer): Boolean;
begin
  fox_w := w;
  fox_h := h;

  fox_sun_dir := v3_norm(v3(-0.42, -0.62, -0.36));
  fox_sun_color := v3(5.2, 4.6, 3.9);
  fox_sky_zenith := v3(0.16, 0.30, 0.62);
  fox_sky_horizon := v3(0.62, 0.70, 0.84);
  fox_ground_color := v3(0.22, 0.20, 0.17);
  fox_fog_color := v3(0.52, 0.60, 0.72);
  fox_fog_density := 0.012;
  fox_fog_height := 26.0;
  fox_exposure := 1.0;

  glGenVertexArrays(1, @g_quadVAO);

  p_gbuf   := link_prog(VS_GBUF, FS_GBUF);
  p_shadow := link_prog(VS_SHADOW, FS_SHADOW);
  p_ssao   := link_prog(VS_FULL, FS_SSAO);
  p_aoblur := link_prog(VS_FULL, FS_AOBLUR);
  p_light  := link_prog(VS_FULL, FS_LIGHT);
  p_bright := link_prog(VS_FULL, FS_BRIGHT);
  p_kawase := link_prog(VS_FULL, FS_KAWASE);
  p_comp   := link_prog(VS_FULL, FS_COMPOSITE);
  p_fxaa   := link_prog(VS_FULL, FS_FXAA);
  p_blit   := link_prog(VS_FULL, FS_BLIT);

  Result := (p_gbuf <> 0) and (p_shadow <> 0) and (p_ssao <> 0) and
            (p_aoblur <> 0) and (p_light <> 0) and (p_bright <> 0) and
            (p_kawase <> 0) and (p_comp <> 0) and (p_fxaa <> 0) and
            (p_blit <> 0);
  if not Result then Exit;

  g_gbuf   := make_target(w, h, 3, True, True, False);
  g_scene  := make_target(w, h, 1, True, False, False);
  g_ao     := make_target(w div 2, h div 2, 1, False, False, False);
  g_aoblur := make_target(w div 2, h div 2, 1, False, False, False);
  g_bright := make_target(w div 2, h div 2, 1, False, False, False);
  g_blurA  := make_target(w div 2, h div 2, 1, False, False, False);
  g_blurB  := make_target(w div 2, h div 2, 1, False, False, False);

  { карты теней: только глубина }
  for fox_w := 0 to FOX_CASCADES - 1 do
    g_shadow[fox_w] := make_target(FOX_SHADOW_RES, FOX_SHADOW_RES, 0,
                                   False, True, True);
  fox_w := w;

  fox_update_sky;
  Result := True;
end;

procedure fox_shutdown;
begin
  { В этом демо контекст всё равно умирает следом, поэтому
    подробная уборка не нужна. }
end;

{ =========================================================================
  Тени: три каскада вдоль пирамиды видимости
  ========================================================================= }

procedure fox_shadow_setup(const cam: TCamera);
var
  i, k: Integer;
  near_, far_: Single;
  cd: Integer;
  centre, lightPos, up: TVec3;
  radius: Single;
  view, proj: TMat4;
  corners: array[0..7] of TVec3;
  texel: Single;
begin
  g_cam := cam;
  g_splits := v3(cam.zfar * 0.045, cam.zfar * 0.14, cam.zfar);

  { Углы каскада считаем прямо из базиса камеры -- это надёжнее, чем
    обращать перспективную матрицу. }
  for i := 0 to FOX_CASCADES - 1 do
  begin
    if i = 0 then near_ := cam.znear
    else if i = 1 then near_ := g_splits.x * 0.95
    else near_ := g_splits.y * 0.95;
    if i = 0 then far_ := g_splits.x
    else if i = 1 then far_ := g_splits.y
    else far_ := g_splits.z;

    { восемь углов усечённой пирамиды в мире }
    k := 0;
    for cd := 0 to 1 do
    begin
      if cd = 0 then texel := near_ else texel := far_;
      corners[k] := v3_add(v3_add(cam.pos, v3_mul(cam.forward_, texel)),
        v3_add(v3_mul(cam.right, -texel * Tan(cam.fov * 0.5) * cam.aspect),
               v3_mul(cam.up, -texel * Tan(cam.fov * 0.5))));
      Inc(k);
      corners[k] := v3_add(v3_add(cam.pos, v3_mul(cam.forward_, texel)),
        v3_add(v3_mul(cam.right,  texel * Tan(cam.fov * 0.5) * cam.aspect),
               v3_mul(cam.up, -texel * Tan(cam.fov * 0.5))));
      Inc(k);
      corners[k] := v3_add(v3_add(cam.pos, v3_mul(cam.forward_, texel)),
        v3_add(v3_mul(cam.right, -texel * Tan(cam.fov * 0.5) * cam.aspect),
               v3_mul(cam.up,  texel * Tan(cam.fov * 0.5))));
      Inc(k);
      corners[k] := v3_add(v3_add(cam.pos, v3_mul(cam.forward_, texel)),
        v3_add(v3_mul(cam.right,  texel * Tan(cam.fov * 0.5) * cam.aspect),
               v3_mul(cam.up,  texel * Tan(cam.fov * 0.5))));
      Inc(k);
    end;

    centre := v3_zero;
    for k := 0 to 7 do centre := v3_add(centre, corners[k]);
    centre := v3_mul(centre, 1.0 / 8.0);

    radius := 0;
    for k := 0 to 7 do radius := fmax(radius, v3_dist(centre, corners[k]));
    radius := Ceil(radius * 16.0) / 16.0;

    { Привязка к сетке текселей: иначе тени "плывут" при движении камеры. }
    texel := (radius * 2.0) / FOX_SHADOW_RES;
    centre.x := Floor(centre.x / texel) * texel;
    centre.y := Floor(centre.y / texel) * texel;
    centre.z := Floor(centre.z / texel) * texel;

    lightPos := v3_sub(centre, v3_mul(fox_sun_dir, radius * 2.2));
    up := v3(0, 1, 0);
    if Abs(fox_sun_dir.y) > 0.98 then up := v3(0, 0, 1);
    view := m4_lookat(lightPos, centre, up);
    proj := m4_ortho(-radius, radius, -radius, radius, 0.05, radius * 5.0);
    g_lightVP[i] := m4_mul(proj, view);
    if fox_verbose then
      WriteLn(Format('[fox] каскад %d: центр (%.2f %.2f %.2f) r=%.2f, свет (%.2f %.2f %.2f)',
        [i, centre.x, centre.y, centre.z, radius, lightPos.x, lightPos.y, lightPos.z]));
  end;

end;

procedure fox_shadow_begin(cascade: Integer);
begin
  glBindFramebuffer(GL_FRAMEBUFFER, g_shadow[cascade].fbo);
  glViewport(0, 0, FOX_SHADOW_RES, FOX_SHADOW_RES);
  glEnable(GL_DEPTH_TEST);
  glDepthFunc(GL_LESS);
  glDepthMask(GL_TRUE);
  glClear(GL_DEPTH_BUFFER_BIT);
  { Отсечение задних граней, как в основном проходе. Отрезать ПЕРЕДНИЕ
    грани тут нельзя: пол -- это большой закрытый ящик, и тогда в карту
    попадёт глубина его дальней стенки, а не поверхности земли. Вместо
    этого от самозатенения спасает смещение полигонов. }
  glEnable(GL_CULL_FACE);
  glCullFace(GL_BACK);
  glEnable(GL_POLYGON_OFFSET_FILL);
  glPolygonOffset(2.5, 4.0);
  glUseProgram(p_shadow);
  setm4(p_shadow, 'uLightVP', g_lightVP[cascade]);
end;

procedure fox_shadow_draw(var m: TMesh; const inst: array of TInstance;
                          count: Integer);
begin
  if count <= 0 then Exit;
  mesh_update_instances(m, inst, count);
  mesh_draw_instanced(m, count);
end;

procedure fox_shadow_end;
begin
  glDisable(GL_POLYGON_OFFSET_FILL);
  glCullFace(GL_BACK);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
end;

{ =========================================================================
  G-буфер
  ========================================================================= }

procedure fox_gbuffer_begin(const cam: TCamera);
begin
  g_cam := cam;
  glBindFramebuffer(GL_FRAMEBUFFER, g_gbuf.fbo);
  glViewport(0, 0, fox_w, fox_h);
  glClearColor(0, 0, 0, 0);
  glClearDepth(1.0);
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT);
  glEnable(GL_DEPTH_TEST);
  glDepthFunc(GL_LESS);
  glDepthMask(GL_TRUE);
  glEnable(GL_CULL_FACE);
  glCullFace(GL_BACK);
  glDisable(GL_BLEND);
  glUseProgram(p_gbuf);
  setm4(p_gbuf, 'uViewProj', cam.viewproj);
end;

procedure fox_draw(var m: TMesh; const inst: array of TInstance;
                   count: Integer);
begin
  if count <= 0 then Exit;
  mesh_update_instances(m, inst, count);
  mesh_draw_instanced(m, count);
end;

procedure fox_gbuffer_end;
begin
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
end;

{ =========================================================================
  Освещение и постобработка
  ========================================================================= }

procedure pass_ssao;
begin
  glBindFramebuffer(GL_FRAMEBUFFER, g_ao.fbo);
  glViewport(0, 0, g_ao.w, g_ao.h);
  glDisable(GL_DEPTH_TEST);
  glUseProgram(p_ssao);
  bind_tex(p_ssao, 'uDepth', 0, g_gbuf.depthTex);
  bind_tex(p_ssao, 'uNormal', 1, g_gbuf.tex[1]);
  setm4(p_ssao, 'uInvViewProj', m4_inverse(g_cam.viewproj));
  setm4(p_ssao, 'uViewProj', g_cam.viewproj);
  set3v(p_ssao, 'uCamPos', g_cam.pos);
  set2f(p_ssao, 'uNearFar', g_cam.znear, g_cam.zfar);
  set2f(p_ssao, 'uPixel', 1.0 / g_ao.w, 1.0 / g_ao.h);
  set1f(p_ssao, 'uRadius', fox_ssao_radius);
  set1f(p_ssao, 'uPower', fox_ssao_power);
  draw_fullscreen;

  glBindFramebuffer(GL_FRAMEBUFFER, g_aoblur.fbo);
  glUseProgram(p_aoblur);
  bind_tex(p_aoblur, 'uAO', 0, g_ao.tex[0]);
  bind_tex(p_aoblur, 'uDepth', 1, g_gbuf.depthTex);
  set2f(p_aoblur, 'uPixel', 1.0 / g_ao.w, 1.0 / g_ao.h);
  draw_fullscreen;
end;

procedure pass_light;
var i: Integer;
begin
  glBindFramebuffer(GL_FRAMEBUFFER, g_scene.fbo);
  glViewport(0, 0, fox_w, fox_h);
  glDisable(GL_DEPTH_TEST);
  glUseProgram(p_light);

  bind_tex(p_light, 'uAlbedo', 0, g_gbuf.tex[0]);
  bind_tex(p_light, 'uNormal', 1, g_gbuf.tex[1]);
  bind_tex(p_light, 'uMaterial', 2, g_gbuf.tex[2]);
  bind_tex(p_light, 'uDepth', 3, g_gbuf.depthTex);
  bind_tex(p_light, 'uAO', 4, g_aoblur.tex[0]);
  bind_tex(p_light, 'uShadow0', 5, g_shadow[0].depthTex);
  bind_tex(p_light, 'uShadow1', 6, g_shadow[1].depthTex);
  bind_tex(p_light, 'uShadow2', 7, g_shadow[2].depthTex);

  setm4(p_light, 'uInvViewProj', m4_inverse(g_cam.viewproj));
  setm4(p_light, 'uLightVP0', g_lightVP[0]);
  setm4(p_light, 'uLightVP1', g_lightVP[1]);
  setm4(p_light, 'uLightVP2', g_lightVP[2]);
  set3v(p_light, 'uCamPos', g_cam.pos);
  set3v(p_light, 'uSunDir', fox_sun_dir);
  set3v(p_light, 'uSunColor', fox_sun_color);
  set3v(p_light, 'uSkyZenith', fox_sky_zenith);
  set3v(p_light, 'uSkyHorizon', fox_sky_horizon);
  set3v(p_light, 'uGround', fox_ground_color);
  set3v(p_light, 'uFogColor', fox_fog_color);
  set3v(p_light, 'uCascadeSplits', g_splits);
  set2f(p_light, 'uFog', fox_fog_density, fox_fog_height);
  set1f(p_light, 'uExposure', fox_exposure);
  if fox_shadows then set1f(p_light, 'uShadowOn', 1.0)
  else set1f(p_light, 'uShadowOn', 0.0);
  if fox_ssao then set1f(p_light, 'uAOOn', 1.0)
  else set1f(p_light, 'uAOOn', 0.0);
  set1f(p_light, 'uDebug', fox_debug_light);

  for i := 0 to 8 do
    glUniform3f(glGetUniformLocation(p_light,
                PChar('uSH[' + IntToStr(i) + ']')),
                g_sh[i].x, g_sh[i].y, g_sh[i].z);

  draw_fullscreen;
end;

procedure pass_bloom;
var
  i: Integer;
  src, dst: TFoxTarget;
  tmp: TFoxTarget;
begin
  { яркий проход }
  glBindFramebuffer(GL_FRAMEBUFFER, g_bright.fbo);
  glViewport(0, 0, g_bright.w, g_bright.h);
  glUseProgram(p_bright);
  bind_tex(p_bright, 'uScene', 0, g_scene.tex[0]);
  set1f(p_bright, 'uThreshold', fox_bloom_thr);
  draw_fullscreen;

  { четыре итерации Кавасэ }
  src := g_bright;
  dst := g_blurA;
  glUseProgram(p_kawase);
  set2f(p_kawase, 'uPixel', 1.0 / g_blurA.w, 1.0 / g_blurA.h);
  for i := 0 to 3 do
  begin
    glBindFramebuffer(GL_FRAMEBUFFER, dst.fbo);
    bind_tex(p_kawase, 'uTex', 0, src.tex[0]);
    set1f(p_kawase, 'uOffset', i * 1.0);
    draw_fullscreen;
    tmp := src;
    src := dst;
    if i = 0 then dst := g_blurB else dst := tmp;
  end;
  { итог размытия остался в src }
  g_bright := src;
end;

procedure fox_resolve(targetFBO: GLuint);
var
  final_: TFoxTarget;
begin
  if fox_ssao then pass_ssao;
  pass_light;

  final_ := g_scene;
  if fox_bloom then pass_bloom;

  { композит: сцена + свечение + виньетка }
  glBindFramebuffer(GL_FRAMEBUFFER, targetFBO);
  glViewport(0, 0, fox_w, fox_h);
  glDisable(GL_DEPTH_TEST);

  glUseProgram(p_comp);
  bind_tex(p_comp, 'uScene', 0, final_.tex[0]);
  bind_tex(p_comp, 'uBloom', 1, g_bright.tex[0]);
  set1f(p_comp, 'uBloomMul', fox_bloom_mul);
  if fox_bloom then set1f(p_comp, 'uBloomOn', 1.0)
  else set1f(p_comp, 'uBloomOn', 0.0);
  draw_fullscreen;
end;

procedure fox_debug_blit(which: Integer; targetFBO: GLuint);
var t: GLuint;
begin
  case which of
    0: t := g_gbuf.tex[0];
    1: t := g_gbuf.tex[1];
    2: t := g_gbuf.tex[2];
    3: t := g_aoblur.tex[0];
    4: t := g_bright.tex[0];
    5: t := g_shadow[0].depthTex;
    6: t := g_shadow[1].depthTex;
    7: t := g_shadow[2].depthTex;
  else
    t := g_scene.tex[0];
  end;
  glBindFramebuffer(GL_FRAMEBUFFER, targetFBO);
  glViewport(0, 0, fox_w, fox_h);
  glDisable(GL_DEPTH_TEST);
  glUseProgram(p_blit);
  bind_tex(p_blit, 'uTex', 0, t);
  if which = 1 then
  begin
    set1f(p_blit, 'uScale', 0.5);
    set1f(p_blit, 'uBias', 0.5);
  end
  else if which >= 5 then
  begin
    { глубина лежит почти вплотную к единице -- растягиваем }
    set1f(p_blit, 'uScale', 6.0);
    set1f(p_blit, 'uBias', -5.0);
  end
  else
  begin
    set1f(p_blit, 'uScale', 1.0);
    set1f(p_blit, 'uBias', 0.0);
  end;
  draw_fullscreen;
end;

end.
