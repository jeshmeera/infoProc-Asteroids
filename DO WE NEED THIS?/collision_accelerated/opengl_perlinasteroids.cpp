// deps: glad, GLFW, GLM. Link: glfw3.lib, opengl32.lib

#include <glad/glad.h>
#include <GLFW/glfw3.h>
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <glm/gtc/type_ptr.hpp>
#include <vector>
#include <random>
#include <chrono>
#include <iostream>
#include <cmath>
#include <algorithm>

static const unsigned int SCR_WIDTH = 1280;
static const unsigned int SCR_HEIGHT = 720;

static std::mt19937_64 rng((unsigned long long)std::chrono::high_resolution_clock::now().time_since_epoch().count());
static float randf(float a, float b) {
    std::uniform_real_distribution<float> d(a, b);
    return d(rng);
}

struct Mesh {
    std::vector<float>        verts;   // interleaved pos+normal, 6 floats per vert
    std::vector<unsigned int> indices; // unused for asteroids (flat shaded, no shared verts)
};

// 3D perlin noise, no external deps
namespace Perlin {
    static int  perm[512];
    static bool seeded = false;

    static void seed(unsigned int s) {
        std::mt19937 gen(s);
        for (int i = 0; i < 256; i++) perm[i] = i;
        for (int i = 255; i > 0; i--) {
            int j = gen() % (i + 1);
            std::swap(perm[i], perm[j]);
        }
        for (int i = 0; i < 256; i++) perm[256 + i] = perm[i];
        seeded = true;
    }

    static float fade(float t) { return t * t * t * (t * (t * 6 - 15) + 10); }
    static float lerp(float a, float b, float t) { return a + t * (b - a); }

    static float grad(int hash, float x, float y, float z) {
        int   h = hash & 15;
        float u = h < 8 ? x : y;
        float v = h < 4 ? y : (h == 12 || h == 14 ? x : z);
        return ((h & 1) ? -u : u) + ((h & 2) ? -v : v);
    }

    static float noise(float x, float y, float z) {
        if (!seeded) seed(42);
        int X = (int)floorf(x) & 255;
        int Y = (int)floorf(y) & 255;
        int Z = (int)floorf(z) & 255;
        x -= floorf(x); y -= floorf(y); z -= floorf(z);
        float u = fade(x), v = fade(y), w = fade(z);
        int A = perm[X] + Y, AA = perm[A] + Z, AB = perm[A + 1] + Z;
        int B = perm[X + 1] + Y, BA = perm[B] + Z, BB = perm[B + 1] + Z;
        return lerp(
            lerp(lerp(grad(perm[AA], x, y, z), grad(perm[BA], x - 1, y, z), u),
                lerp(grad(perm[AB], x, y - 1, z), grad(perm[BB], x - 1, y - 1, z), u), v),
            lerp(lerp(grad(perm[AA + 1], x, y, z - 1), grad(perm[BA + 1], x - 1, y, z - 1), u),
                lerp(grad(perm[AB + 1], x, y - 1, z - 1), grad(perm[BB + 1], x - 1, y - 1, z - 1), u), v),
            w);
    }

    // layered octaves — gives the rocky lumpy look vs single-octave smoothness
    static float fbm(float x, float y, float z, int octaves = 3) {
        float val = 0, amp = 0.5f, freq = 1.0f, mx = 0;
        for (int i = 0; i < octaves; i++) {
            val += noise(x * freq, y * freq, z * freq) * amp;
            mx += amp;
            amp *= 0.5f;
            freq *= 2.1f;
        }
        return val / mx;
    }
}

struct IcoVert { glm::vec3 p; };
struct IcoFace { int a, b, c; };

static int addIcoVert(std::vector<IcoVert>& v, glm::vec3 p) {
    v.push_back({ glm::normalize(p) });
    return (int)v.size() - 1;
}

static int midpoint(std::vector<IcoVert>& v, int a, int b) {
    return addIcoVert(v, (v[a].p + v[b].p) * 0.5f);
}

static void buildIcosahedron(std::vector<IcoVert>& verts, std::vector<IcoFace>& faces) {
    const float t = (1.0f + sqrtf(5.0f)) / 2.0f;
    addIcoVert(verts, { -1, t, 0 }); addIcoVert(verts, { 1, t, 0 });
    addIcoVert(verts, { -1,-t, 0 }); addIcoVert(verts, { 1,-t, 0 });
    addIcoVert(verts, { 0,-1, t }); addIcoVert(verts, { 0, 1, t });
    addIcoVert(verts, { 0,-1,-t }); addIcoVert(verts, { 0, 1,-t });
    addIcoVert(verts, { t, 0,-1 }); addIcoVert(verts, { t, 0, 1 });
    addIcoVert(verts, { -t, 0,-1 }); addIcoVert(verts, { -t, 0, 1 });
    faces = {
        {0,11,5},{0,5,1},{0,1,7},{0,7,10},{0,10,11},
        {1,5,9},{5,11,4},{11,10,2},{10,7,6},{7,1,8},
        {3,9,4},{3,4,2},{3,2,6},{3,6,8},{3,8,9},
        {4,9,5},{2,4,11},{6,2,10},{8,6,7},{9,8,1}
    };
}

static void subdivide(std::vector<IcoVert>& verts, std::vector<IcoFace>& faces) {
    std::vector<IcoFace> nf;
    nf.reserve(faces.size() * 4);
    for (auto& f : faces) {
        int ab = midpoint(verts, f.a, f.b);
        int bc = midpoint(verts, f.b, f.c);
        int ca = midpoint(verts, f.c, f.a);
        nf.push_back({ f.a,ab,ca }); nf.push_back({ f.b,bc,ab });
        nf.push_back({ f.c,ca,bc }); nf.push_back({ ab,bc,ca });
    }
    faces = nf;
}

// subdivisions=2 gives 320 tris, noiseAmp=0.3 is rocky but not insane
// each asteroid gets a different noiseSeed so they all look unique
Mesh createAsteroid(unsigned int subdivisions = 2, float noiseScale = 1.8f, float noiseAmp = 0.30f, unsigned int noiseSeed = 0) {
    Perlin::seed(noiseSeed);

    std::vector<IcoVert> verts;
    std::vector<IcoFace> faces;
    buildIcosahedron(verts, faces);
    for (unsigned int i = 0; i < subdivisions; i++) subdivide(verts, faces);

    for (auto& v : verts) {
        float n = Perlin::fbm(v.p.x * noiseScale, v.p.y * noiseScale, v.p.z * noiseScale, 3);
        v.p *= (1.0f + n * noiseAmp);
    }

    // flat shading: each tri needs its own 3 verts since they all share one face normal
    Mesh m;
    m.verts.reserve(faces.size() * 3 * 6);
    for (auto& f : faces) {
        glm::vec3 A = verts[f.a].p;
        glm::vec3 B = verts[f.b].p;
        glm::vec3 C = verts[f.c].p;
        glm::vec3 n = glm::normalize(glm::cross(B - A, C - A));
        for (auto& p : { A, B, C }) {
            m.verts.push_back(p.x); m.verts.push_back(p.y); m.verts.push_back(p.z);
            m.verts.push_back(n.x); m.verts.push_back(n.y); m.verts.push_back(n.z);
        }
    }
    return m;
}

static const float cubeVerts[] = {
    -0.5f,-0.5f,-0.5f, 0,0,-1,  0.5f, 0.5f,-0.5f, 0,0,-1,  0.5f,-0.5f,-0.5f, 0,0,-1,
     0.5f, 0.5f,-0.5f, 0,0,-1, -0.5f,-0.5f,-0.5f, 0,0,-1, -0.5f, 0.5f,-0.5f, 0,0,-1,
    -0.5f,-0.5f, 0.5f, 0,0, 1,  0.5f,-0.5f, 0.5f, 0,0, 1,  0.5f, 0.5f, 0.5f, 0,0, 1,
     0.5f, 0.5f, 0.5f, 0,0, 1, -0.5f, 0.5f, 0.5f, 0,0, 1, -0.5f,-0.5f, 0.5f, 0,0, 1,
    -0.5f, 0.5f, 0.5f,-1,0, 0, -0.5f, 0.5f,-0.5f,-1,0, 0, -0.5f,-0.5f,-0.5f,-1,0, 0,
    -0.5f,-0.5f,-0.5f,-1,0, 0, -0.5f,-0.5f, 0.5f,-1,0, 0, -0.5f, 0.5f, 0.5f,-1,0, 0,
     0.5f, 0.5f, 0.5f, 1,0, 0,  0.5f,-0.5f,-0.5f, 1,0, 0,  0.5f, 0.5f,-0.5f, 1,0, 0,
     0.5f,-0.5f,-0.5f, 1,0, 0,  0.5f, 0.5f, 0.5f, 1,0, 0,  0.5f,-0.5f, 0.5f, 1,0, 0,
    -0.5f,-0.5f,-0.5f, 0,-1,0,  0.5f,-0.5f,-0.5f, 0,-1,0,  0.5f,-0.5f, 0.5f, 0,-1,0,
     0.5f,-0.5f, 0.5f, 0,-1,0, -0.5f,-0.5f, 0.5f, 0,-1,0, -0.5f,-0.5f,-0.5f, 0,-1,0,
    -0.5f, 0.5f,-0.5f, 0, 1,0,  0.5f, 0.5f, 0.5f, 0, 1,0,  0.5f, 0.5f,-0.5f, 0, 1,0,
     0.5f, 0.5f, 0.5f, 0, 1,0, -0.5f, 0.5f,-0.5f, 0, 1,0, -0.5f, 0.5f, 0.5f, 0, 1,0
};

struct Asteroid {
    glm::vec3    pos, vel;
    float        radius;
    glm::vec3    axis;
    float        angle, rotSpeed;
    glm::vec3    tint;
    unsigned int meshSeed; // each asteroid gets a unique perlin seed = unique shape
};

class CollisionEngine {
public:
    CollisionEngine(int asteroidCount = 75)
        : ASTEROID_COUNT(asteroidCount),
        shipPos(0, 0, 0), shipVel(0), shipSpeed(12.0f), shipRadius(0.6f),
        gameOver(false)
    {
        pool.reserve(ASTEROID_COUNT);
        initPool();
    }

    void reset() {
        shipPos = glm::vec3(0, 0, 0);
        shipVel = glm::vec3(0, 0, 0);
        gameOver = false;
        initPool();
    }

    void update(float dt, float lateralInput, float verticalInput) {
        if (gameOver) return;

        // exponential smoothing toward desired velocity, feels better than instant
        glm::vec3 desired = glm::vec3(lateralInput * shipSpeed, verticalInput * shipSpeed, 0.0f);
        shipVel = glm::mix(shipVel, desired, glm::clamp(6.0f * dt, 0.0f, 1.0f));
        shipPos += shipVel * dt;
        shipPos.x = glm::clamp(shipPos.x, -X_LIMIT, X_LIMIT);
        shipPos.y = glm::clamp(shipPos.y, -Y_LIMIT, Y_LIMIT);

        for (auto& a : pool) {
            a.pos += a.vel * dt;
            a.angle += a.rotSpeed * dt;
        }

        resolveAsteroidCollisions();

        for (auto& a : pool) {
            if (glm::length(shipPos - a.pos) < shipRadius + a.radius) {
                gameOver = true;
                return;
            }
        }

        // respawn asteroids that have passed behind the camera
        for (auto& a : pool) {
            if (a.pos.z > shipPos.z + 8.0f) {
                spawnAsteroid(a);
                a.pos.z = shipPos.z - randf(60.0f, 380.0f);
            }
        }
    }

    const std::vector<Asteroid>& getPool()       const { return pool; }
    const glm::vec3& getShipPos()    const { return shipPos; }
    const glm::vec3& getShipVel()    const { return shipVel; }
    float                        getShipRadius() const { return shipRadius; }
    bool                         isGameOver()    const { return gameOver; }

private:
    const int   ASTEROID_COUNT;
    const float X_LIMIT = 18.0f;
    const float Y_LIMIT = 9.0f;

    glm::vec3 shipPos, shipVel;
    float     shipSpeed, shipRadius;
    bool      gameOver;

    std::vector<Asteroid> pool;
    glm::vec3 asteroidBase = glm::vec3(0.42f, 0.40f, 0.36f);

    void initPool() {
        pool.clear();
        for (int i = 0; i < ASTEROID_COUNT; ++i) {
            Asteroid a; spawnAsteroid(a);
            pool.push_back(a);
        }
    }

    void spawnAsteroid(Asteroid& a) {
        a.radius = randf(0.35f, 1.8f);
        a.pos = glm::vec3(randf(-22, 22), randf(-10, 10), shipPos.z - randf(30, 320));
        a.vel = glm::vec3(randf(-1.5f, 1.5f), randf(-1.2f, 1.2f), randf(6, 18));
        a.axis = glm::normalize(glm::vec3(randf(-1, 1), randf(-1, 1), randf(-1, 1)));
        a.angle = randf(0, 360);
        a.rotSpeed = randf(-60, 60);
        a.tint = glm::vec3(randf(-0.06f, 0.06f), randf(-0.05f, 0.05f), randf(-0.04f, 0.04f));
        a.meshSeed = (unsigned int)(rng() & 0xFFFFFFFF);
    }

    void resolveAsteroidCollisions() {
        const float EPS = 1e-5f, restitution = 1.0f;
        int n = (int)pool.size();
        for (int i = 0; i < n; ++i) {
            for (int j = i + 1; j < n; ++j) {
                Asteroid& A = pool[i]; Asteroid& B = pool[j];
                glm::vec3 dp = A.pos - B.pos;
                float dist2 = glm::dot(dp, dp), rSum = A.radius + B.radius;
                if (dist2 > rSum * rSum) continue;

                float dist = sqrtf(std::max(dist2, EPS));
                glm::vec3 nrm = dp / dist;
                // guard against NaN if asteroids are perfectly overlapping
                if (!std::isfinite(nrm.x))
                    nrm = glm::normalize(glm::vec3(randf(-1, 1), randf(-1, 1), randf(-1, 1)));

                float mA = A.radius * A.radius * A.radius, mB = B.radius * B.radius * B.radius;
                float relVel = glm::dot(A.vel - B.vel, nrm);
                if (relVel < 0.0f) {
                    float j = -(1.0f + restitution) * relVel / (1.0f / mA + 1.0f / mB);
                    glm::vec3 imp = j * nrm;
                    A.vel += imp / mA; B.vel -= imp / mB;
                }
                // positional correction so they don't sink into each other over time
                float pen = rSum - dist;
                if (pen > 0.0f) {
                    glm::vec3 corr = (pen / (mA + mB)) * 0.8f * nrm;
                    A.pos += corr * mB; B.pos -= corr * mA;
                }
            }
        }
    }
};

class Renderer {
public:
    Renderer(const CollisionEngine& physicsRef)
        : physics(physicsRef),
        cameraOffset(0, 1.6f, 6.5f),
        camPosPrev(physicsRef.getShipPos() + glm::vec3(0, 1.6f, 6.5f)),
        fov(62.0f)
    {
        glEnable(GL_DEPTH_TEST);
        glEnable(GL_CULL_FACE); glCullFace(GL_BACK);
        glEnable(GL_PROGRAM_POINT_SIZE);

        compileShaders();
        setupMeshes();
        setupStars();
        setupOverlay();

        lightDir = glm::normalize(glm::vec3(0.4f, 0.9f, 0.25f));
        ambient = 0.26f;
        shininess = 30.0f;
        fogColor = glm::vec3(0.05f, 0.06f, 0.10f);
        fogStart = 20.0f;
        fogEnd = 320.0f;
        shipColor = glm::vec3(1.00f, 0.66f, 0.28f);
        asteroidBase = glm::vec3(0.42f, 0.40f, 0.36f);
    }

    ~Renderer() {
        glDeleteProgram(objProg);
        glDeleteProgram(starProg);
        glDeleteProgram(overlayProg);
        glDeleteVertexArrays(1, &cubeVAO);    glDeleteBuffers(1, &cubeVBO);
        glDeleteVertexArrays(1, &starVAO);    glDeleteBuffers(1, &starVBO);
        glDeleteVertexArrays(1, &overlayVAO); glDeleteBuffers(1, &overlayVBO);
        for (auto& v : asteroidVAOs) glDeleteVertexArrays(1, &v);
        for (auto& v : asteroidVBOs) glDeleteBuffers(1, &v);
    }

    void render(float dt) {
        const glm::vec3 shipPos = physics.getShipPos();
        glm::vec3       camTarget = shipPos + cameraOffset;
        float           smooth = glm::clamp(8.0f * dt, 0.0f, 1.0f);
        camPosPrev = glm::mix(camPosPrev, camTarget, smooth);
        glm::vec3 camPos = camPosPrev;
        glm::vec3 camLook = shipPos + glm::vec3(0, 0.35f, 0);
        glm::mat4 view = glm::lookAt(camPos, camLook, glm::vec3(0, 1, 0));
        glm::mat4 proj = glm::perspective(glm::radians(fov), (float)SCR_WIDTH / SCR_HEIGHT, 0.1f, 2000.0f);

        glClearColor(fogColor.r, fogColor.g, fogColor.b, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        // stars — additive blend so overlapping stars brighten naturally
        glUseProgram(starProg);
        glUniformMatrix4fv(glGetUniformLocation(starProg, "view"), 1, GL_FALSE, glm::value_ptr(view));
        glUniformMatrix4fv(glGetUniformLocation(starProg, "projection"), 1, GL_FALSE, glm::value_ptr(proj));
        glBindVertexArray(starVAO);
        glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA, GL_ONE);
        glDepthMask(GL_FALSE);
        glDrawArrays(GL_POINTS, 0, STAR_COUNT);
        glDepthMask(GL_TRUE); glDisable(GL_BLEND);

        glUseProgram(objProg);
        glUniformMatrix4fv(glGetUniformLocation(objProg, "view"), 1, GL_FALSE, glm::value_ptr(view));
        glUniformMatrix4fv(glGetUniformLocation(objProg, "projection"), 1, GL_FALSE, glm::value_ptr(proj));
        glUniform3fv(glGetUniformLocation(objProg, "lightDir"), 1, glm::value_ptr(lightDir));
        glUniform3fv(glGetUniformLocation(objProg, "viewPos"), 1, glm::value_ptr(camPos));
        glUniform1f(glGetUniformLocation(objProg, "ambientStrength"), ambient);
        glUniform1f(glGetUniformLocation(objProg, "shininess"), shininess);
        glUniform3fv(glGetUniformLocation(objProg, "fogColor"), 1, glm::value_ptr(fogColor));
        glUniform1f(glGetUniformLocation(objProg, "fogStart"), fogStart);
        glUniform1f(glGetUniformLocation(objProg, "fogEnd"), fogEnd);

        // ship rolls slightly when strafing
        float roll = glm::clamp(-physics.getShipVel().x * 0.02f, -0.25f, 0.25f);
        glm::mat4 shipModel(1);
        shipModel = glm::translate(shipModel, shipPos);
        shipModel = glm::rotate(shipModel, roll, glm::vec3(0, 0, 1));
        shipModel = glm::scale(shipModel, glm::vec3(1.0f, 0.48f, 1.8f));
        glUniformMatrix4fv(glGetUniformLocation(objProg, "model"), 1, GL_FALSE, glm::value_ptr(shipModel));
        glUniform3f(glGetUniformLocation(objProg, "objectColor"), shipColor.r, shipColor.g, shipColor.b);
        glBindVertexArray(cubeVAO);
        glDrawArrays(GL_TRIANGLES, 0, 36);

        const auto& pool = physics.getPool();
        for (int i = 0; i < (int)pool.size(); ++i) {
            const auto& a = pool[i];
            // rebuild mesh if this slot just respawned with a new seed
            if (i >= (int)asteroidSeeds.size() || asteroidSeeds[i] != a.meshSeed)
                rebuildAsteroidMesh(i, a.meshSeed);

            glm::mat4 model(1);
            model = glm::translate(model, a.pos);
            model = glm::rotate(model, glm::radians(a.angle), a.axis);
            model = glm::scale(model, glm::vec3(a.radius));
            glUniformMatrix4fv(glGetUniformLocation(objProg, "model"), 1, GL_FALSE, glm::value_ptr(model));
            float shade = glm::clamp(0.6f + (a.radius / 3.5f), 0.55f, 1.05f);
            glm::vec3 col = glm::clamp(asteroidBase * shade + a.tint, glm::vec3(0.08f), glm::vec3(1.0f));
            glUniform3f(glGetUniformLocation(objProg, "objectColor"), col.r, col.g, col.b);
            glBindVertexArray(asteroidVAOs[i]);
            glDrawArrays(GL_TRIANGLES, 0, asteroidVertCounts[i]);
        }

        if (physics.isGameOver()) renderOverlay();
    }

private:
    const CollisionEngine& physics;

    GLuint objProg = 0, starProg = 0, overlayProg = 0;
    GLuint cubeVAO = 0, cubeVBO = 0;
    GLuint starVAO = 0, starVBO = 0;
    GLuint overlayVAO = 0, overlayVBO = 0;
    const int STAR_COUNT = 420;

    std::vector<GLuint>       asteroidVAOs;
    std::vector<GLuint>       asteroidVBOs;
    std::vector<GLsizei>      asteroidVertCounts;
    std::vector<unsigned int> asteroidSeeds;

    glm::vec3 cameraOffset, camPosPrev;
    float     fov;
    glm::vec3 lightDir;
    float     ambient, shininess;
    glm::vec3 fogColor;
    float     fogStart, fogEnd;
    glm::vec3 shipColor, asteroidBase;

    const char* objVert = R"glsl(
    #version 330 core
    layout(location=0) in vec3 aPos;
    layout(location=1) in vec3 aNormal;
    out vec3 FragPos;
    out vec3 Normal;
    uniform mat4 model, view, projection;
    void main() {
        FragPos     = vec3(model * vec4(aPos, 1.0));
        Normal      = mat3(transpose(inverse(model))) * aNormal;
        gl_Position = projection * view * vec4(FragPos, 1.0);
    })glsl";

    const char* objFrag = R"glsl(
    #version 330 core
    in vec3 FragPos, Normal;
    out vec4 FragColor;
    uniform vec3  objectColor, lightDir, viewPos, fogColor;
    uniform float ambientStrength, shininess, fogStart, fogEnd;
    void main() {
        vec3 n   = normalize(Normal);
        vec3 ld  = normalize(lightDir);
        vec3 vd  = normalize(viewPos - FragPos);
        vec3 h   = normalize(ld + vd);
        vec3 col = ambientStrength * objectColor
                 + max(dot(n, ld), 0.0) * objectColor
                 + pow(max(dot(n, h), 0.0), shininess) * 0.25
                 + pow(1.0 - max(dot(vd, n), 0.0), 2.0) * 0.06 * objectColor;
        float fog = clamp((fogEnd - length(viewPos - FragPos)) / (fogEnd - fogStart), 0.0, 1.0);
        FragColor = vec4(mix(fogColor, col, fog), 1.0);
    })glsl";

    const char* starVert = R"glsl(
    #version 330 core
    layout(location=0) in vec3  aPos;
    layout(location=1) in float aBright;
    uniform mat4 view, projection;
    out float vBright;
    void main() {
        gl_Position  = projection * view * vec4(aPos, 1.0);
        gl_PointSize = clamp(100.0 / (-aPos.z + 12.0), 1.0, 6.0);
        vBright = aBright;
    })glsl";

    const char* starFrag = R"glsl(
    #version 330 core
    in float vBright;
    out vec4 FragColor;
    void main() {
        float d = length(gl_PointCoord - vec2(0.5));
        FragColor = vec4(vec3(1.0) * vBright, smoothstep(0.5, 0.0, d) * vBright);
    })glsl";

    const char* overlayVert = R"glsl(
    #version 330 core
    layout(location=0) in vec2 aPos;
    out vec2 vUV;
    void main() {
        vUV = aPos * 0.5 + 0.5;
        gl_Position = vec4(aPos, 0.0, 1.0);
    })glsl";

    // game over overlay: fullscreen quad + procedural bitmap font (5x7 per glyph, packed as uints)
    const char* overlayFrag = R"glsl(
    #version 330 core
    in  vec2 vUV;
    out vec4 FragColor;

    const uint font[37*7] = uint[](
        0u,0u,0u,0u,0u,0u,0u,
        14u,17u,17u,31u,17u,17u,17u,
        30u,17u,17u,30u,17u,17u,30u,
        14u,17u,16u,16u,16u,17u,14u,
        30u,17u,17u,17u,17u,17u,30u,
        31u,16u,16u,30u,16u,16u,31u,
        31u,16u,16u,30u,16u,16u,16u,
        14u,17u,16u,23u,17u,17u,14u,
        17u,17u,17u,31u,17u,17u,17u,
        14u,4u,4u,4u,4u,4u,14u,
        7u,2u,2u,2u,2u,18u,12u,
        17u,18u,20u,24u,20u,18u,17u,
        16u,16u,16u,16u,16u,16u,31u,
        17u,27u,21u,21u,17u,17u,17u,
        17u,25u,25u,21u,19u,19u,17u,
        14u,17u,17u,17u,17u,17u,14u,
        30u,17u,17u,30u,16u,16u,16u,
        14u,17u,17u,17u,21u,19u,15u,
        30u,17u,17u,30u,20u,18u,17u,
        14u,17u,16u,14u,1u,17u,14u,
        31u,4u,4u,4u,4u,4u,4u,
        17u,17u,17u,17u,17u,17u,14u,
        17u,17u,17u,17u,17u,10u,4u,
        17u,17u,17u,21u,21u,27u,17u,
        17u,17u,10u,4u,10u,17u,17u,
        17u,17u,10u,4u,4u,4u,4u,
        31u,1u,2u,4u,8u,16u,31u,
        14u,17u,19u,21u,25u,17u,14u,
        4u,12u,4u,4u,4u,4u,14u,
        14u,17u,1u,6u,8u,16u,31u,
        31u,1u,2u,6u,1u,17u,14u,
        2u,6u,10u,18u,31u,2u,2u,
        31u,16u,30u,1u,1u,17u,14u,
        6u,8u,16u,30u,17u,17u,14u,
        31u,1u,2u,4u,8u,8u,8u,
        14u,17u,17u,14u,17u,17u,14u,
        14u,17u,17u,15u,1u,2u,12u
    );

    float glyphPixel(int ci, int px, int py) {
        if (ci<0||ci>36||px<0||px>4||py<0||py>6) return 0.0;
        uint row=font[ci*7+py];
        return float((row>>uint(4-px))&1u);
    }
    int charIndex(int c) {
        if (c==32) return 0;
        if (c>=65&&c<=90) return c-64;
        if (c>=48&&c<=57) return c-48+27;
        return 0;
    }
    float drawString(int[24] str, int len, vec2 px, float ox, float oy, float cw, float ch) {
        for (int i=0;i<len;i++) {
            float lx=px.x-(ox+float(i)*cw), ly=px.y-oy;
            if (lx>=0.0&&lx<cw-1.0&&ly>=0.0&&ly<ch) {
                if (glyphPixel(charIndex(str[i]),int(lx/(cw/5.0)),int(ly/(ch/7.0)))>0.5) return 1.0;
            }
        }
        return 0.0;
    }

    void main() {
        vec4 bg=vec4(0.0,0.0,0.0,0.72);
        // flip Y — OpenGL UV origin is bottom-left
        vec2 px=vec2(vUV.x,1.0-vUV.y)*vec2(1280.0,720.0);

        float cw1=52.0,ch1=70.0; int len1=9;
        int str1[24];
        str1[0]=71;str1[1]=65;str1[2]=77;str1[3]=69;str1[4]=32;
        str1[5]=79;str1[6]=86;str1[7]=69;str1[8]=82;
        for(int i=9;i<24;i++) str1[i]=32;
        float ox1=(1280.0-float(len1)*cw1)*0.5, oy1=720.0*0.5-ch1-10.0;

        float cw2=26.0,ch2=35.0; int len2=22;
        int str2[24];
        str2[0]=80;str2[1]=82;str2[2]=69;str2[3]=83;str2[4]=83;str2[5]=32;
        str2[6]=83;str2[7]=80;str2[8]=65;str2[9]=67;str2[10]=69;str2[11]=32;
        str2[12]=84;str2[13]=79;str2[14]=32;
        str2[15]=82;str2[16]=69;str2[17]=83;str2[18]=84;str2[19]=65;
        str2[20]=82;str2[21]=84;
        for(int i=22;i<24;i++) str2[i]=32;
        float ox2=(1280.0-float(len2)*cw2)*0.5, oy2=720.0*0.5+10.0;

        float hit1=drawString(str1,len1,px,ox1,oy1,cw1,ch1);
        float hit2=drawString(str2,len2,px,ox2,oy2,cw2,ch2);
        vec4 textColor=vec4(0.0);
        if(hit1>0.5) textColor=vec4(1.0,0.28,0.18,1.0);
        if(hit2>0.5) textColor=vec4(0.85,0.85,0.85,1.0);
        FragColor=mix(bg,textColor,max(hit1,hit2));
    })glsl";

    static GLuint compileLinkProgram(const char* vsSrc, const char* fsSrc) {
        auto compile = [](GLenum t, const char* src)->GLuint {
            GLuint s = glCreateShader(t);
            glShaderSource(s, 1, &src, nullptr);
            glCompileShader(s);
            GLint ok; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
            if (!ok) {
                GLint len = 0; glGetShaderiv(s, GL_INFO_LOG_LENGTH, &len);
                std::vector<char> buf(len + 1);
                glGetShaderInfoLog(s, len, nullptr, buf.data());
                std::cerr << "Shader error: " << buf.data() << "\n";
            }
            return s;
            };
        GLuint vs = compile(GL_VERTEX_SHADER, vsSrc);
        GLuint fs = compile(GL_FRAGMENT_SHADER, fsSrc);
        GLuint p = glCreateProgram();
        glAttachShader(p, vs); glAttachShader(p, fs);
        glLinkProgram(p);
        GLint ok; glGetProgramiv(p, GL_LINK_STATUS, &ok);
        if (!ok) {
            GLint len = 0; glGetProgramiv(p, GL_INFO_LOG_LENGTH, &len);
            std::vector<char> buf(len + 1);
            glGetProgramInfoLog(p, len, nullptr, buf.data());
            std::cerr << "Link error: " << buf.data() << "\n";
        }
        glDeleteShader(vs); glDeleteShader(fs);
        return p;
    }

    void compileShaders() {
        objProg = compileLinkProgram(objVert, objFrag);
        starProg = compileLinkProgram(starVert, starFrag);
        overlayProg = compileLinkProgram(overlayVert, overlayFrag);
    }

    void rebuildAsteroidMesh(int idx, unsigned int seed) {
        while ((int)asteroidVAOs.size() <= idx) {
            asteroidVAOs.push_back(0);
            asteroidVBOs.push_back(0);
            asteroidVertCounts.push_back(0);
            asteroidSeeds.push_back(0xFFFFFFFF);
        }
        if (asteroidVAOs[idx]) {
            glDeleteVertexArrays(1, &asteroidVAOs[idx]);
            glDeleteBuffers(1, &asteroidVBOs[idx]);
        }
        Mesh m = createAsteroid(2, 1.8f, 0.30f, seed);
        GLuint vao, vbo;
        glGenVertexArrays(1, &vao); glGenBuffers(1, &vbo);
        glBindVertexArray(vao);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, m.verts.size() * sizeof(float), m.verts.data(), GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), (void*)0);                 glEnableVertexAttribArray(0);
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), (void*)(3 * sizeof(float))); glEnableVertexAttribArray(1);
        glBindVertexArray(0);
        asteroidVAOs[idx] = vao;
        asteroidVBOs[idx] = vbo;
        asteroidVertCounts[idx] = (GLsizei)(m.verts.size() / 6);
        asteroidSeeds[idx] = seed;
    }

    void setupMeshes() {
        glGenVertexArrays(1, &cubeVAO); glGenBuffers(1, &cubeVBO);
        glBindVertexArray(cubeVAO);
        glBindBuffer(GL_ARRAY_BUFFER, cubeVBO);
        glBufferData(GL_ARRAY_BUFFER, sizeof(cubeVerts), cubeVerts, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), (void*)0);                 glEnableVertexAttribArray(0);
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), (void*)(3 * sizeof(float))); glEnableVertexAttribArray(1);
        glBindVertexArray(0);
        // asteroid VAOs are built on first render, and rebuilt on respawn
    }

    void setupStars() {
        std::vector<float> stars;
        stars.reserve(STAR_COUNT * 4);
        for (int i = 0; i < STAR_COUNT; ++i) {
            stars.push_back(randf(-220, 220));
            stars.push_back(randf(-140, 140));
            stars.push_back(-randf(40, 900));
            stars.push_back(randf(0.45f, 1.0f));
        }
        glGenVertexArrays(1, &starVAO); glGenBuffers(1, &starVBO);
        glBindVertexArray(starVAO);
        glBindBuffer(GL_ARRAY_BUFFER, starVBO);
        glBufferData(GL_ARRAY_BUFFER, stars.size() * sizeof(float), stars.data(), GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);                 glEnableVertexAttribArray(0);
        glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(3 * sizeof(float))); glEnableVertexAttribArray(1);
        glBindVertexArray(0);
    }

    void setupOverlay() {
        float quad[] = { -1,-1,1,-1,1,1,-1,-1,1,1,-1,1 };
        glGenVertexArrays(1, &overlayVAO); glGenBuffers(1, &overlayVBO);
        glBindVertexArray(overlayVAO);
        glBindBuffer(GL_ARRAY_BUFFER, overlayVBO);
        glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float), (void*)0); glEnableVertexAttribArray(0);
        glBindVertexArray(0);
    }

    void renderOverlay() {
        glDisable(GL_DEPTH_TEST);
        glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(overlayProg);
        glBindVertexArray(overlayVAO);
        glDrawArrays(GL_TRIANGLES, 0, 6);
        glDisable(GL_BLEND);
        glEnable(GL_DEPTH_TEST);
    }
};

bool keys[1024] = {};
bool prevKeys[1024] = {};

void key_callback(GLFWwindow* window, int key, int scancode, int action, int mods) {
    if (key == GLFW_KEY_ESCAPE && action == GLFW_PRESS) glfwSetWindowShouldClose(window, GLFW_TRUE);
    if (key >= 0 && key < 1024) {
        if (action == GLFW_PRESS)        keys[key] = true;
        else if (action == GLFW_RELEASE) keys[key] = false;
    }
}

void framebuffer_size_callback(GLFWwindow*, int w, int h) { glViewport(0, 0, w, h); }

int main() {
    glfwInit();
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);

    GLFWwindow* window = glfwCreateWindow(SCR_WIDTH, SCR_HEIGHT, "Asteroids", nullptr, nullptr);
    if (!window) { std::cerr << "Failed to create window\n"; glfwTerminate(); return -1; }
    glfwMakeContextCurrent(window);
    glfwSetFramebufferSizeCallback(window, framebuffer_size_callback);
    glfwSetKeyCallback(window, key_callback);

    if (!gladLoadGLLoader((GLADloadproc)glfwGetProcAddress)) { std::cerr << "GLAD init failed\n"; return -1; }

    CollisionEngine physics(75);
    Renderer        renderer(physics);

    double lastTime = glfwGetTime();

    while (!glfwWindowShouldClose(window)) {
        double now = glfwGetTime();
        float  dt = (float)(now - lastTime);
        lastTime = now;
        if (dt <= 0.0f) dt = 0.001f;

        // edge detection on space so reset fires once per press, not every frame
        if (physics.isGameOver() && keys[GLFW_KEY_SPACE] && !prevKeys[GLFW_KEY_SPACE])
            physics.reset();
        memcpy(prevKeys, keys, sizeof(keys));

        float lateral = 0, vertical = 0;
        if (!physics.isGameOver()) {
            if (keys[GLFW_KEY_A]) lateral -= 1.0f;
            if (keys[GLFW_KEY_D]) lateral += 1.0f;
            if (keys[GLFW_KEY_W]) vertical += 1.0f;
            if (keys[GLFW_KEY_S]) vertical -= 1.0f;
        }

        physics.update(dt, lateral, vertical);
        renderer.render(dt);

        glfwSwapBuffers(window);
        glfwPollEvents();
    }

    glfwDestroyWindow(window);
    glfwTerminate();
    return 0;
}