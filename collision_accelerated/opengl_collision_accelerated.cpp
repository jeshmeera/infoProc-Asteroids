// deps: glad, GLFW, GLM. Link: glfw3.lib, opengl32.lib
// FPGA build: also link ws2_32.lib (Windows) — no extra lib needed on Linux

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

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")

typedef SOCKET sock_t;
#define SOCK_INVALID INVALID_SOCKET
#define SOCK_ERR     SOCKET_ERROR

static void net_init() { WSADATA w; WSAStartup(MAKEWORD(2, 2), &w); }
static void net_cleanup() { WSACleanup(); }
static void net_close(sock_t s) { closesocket(s); }
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <netinet/tcp.h>

typedef int  sock_t;
#define SOCK_INVALID (-1)
#define SOCK_ERR     (-1)

static void net_init() {}
static void net_cleanup() {}
static void net_close(sock_t s) { close(s); }
#endif

#include <cstdint>
#include <cstring>

/*-------------------------------------------------------
  Fixed-point helpers: Q16.16
-------------------------------------------------------*/

static inline int32_t  f2q(float f) { return (int32_t)(int64_t)roundf(f * 65536.0f); }
static inline float    q2f(int32_t q) { return (float)q / 65536.0f; }
static inline uint32_t f2qu(float f) { return (uint32_t)(int32_t)(int64_t)roundf(f * 65536.0f); }

#pragma pack(push, 1)
struct ColRecord {
    int32_t px, py, pz, vx, vy, vz, radius, mass;
};
#pragma pack(pop)

static_assert(sizeof(ColRecord) == 32, "ColRecord must be 32 bytes");

/*-------------------------------------------------------
  FPGA client that sends/receives ColRecord buffers
-------------------------------------------------------*/

class ColFPGA {
public:
    ColFPGA() : sock(SOCK_INVALID), connected(false) { net_init(); }
    ~ColFPGA() { disconnect(); net_cleanup(); }

    bool connect(const char* host = "192.168.2.99", int port = 5005) {
        sock = ::socket(AF_INET, SOCK_STREAM, 0);
        if (sock == SOCK_INVALID) return false;

        sockaddr_in sa{};
        sa.sin_family = AF_INET;
        sa.sin_port = htons((uint16_t)port);

        if (inet_pton(AF_INET, host, &sa.sin_addr) <= 0) {
            net_close(sock);
            sock = SOCK_INVALID;
            return false;
        }

        if (::connect(sock, (sockaddr*)&sa, sizeof(sa)) == SOCK_ERR) {
            std::cerr << "[FPGA] connect() failed\n";
            net_close(sock);
            sock = SOCK_INVALID;
            return false;
        }

        int flag = 1;
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (char*)&flag, sizeof(flag));
        connected = true;
        std::cout << "[FPGA] Connected to " << host << ":" << port << "\n";
        return true;
    }

    void disconnect() {
        if (sock != SOCK_INVALID) {
            net_close(sock);
            sock = SOCK_INVALID;
        }
        connected = false;
    }

    bool isConnected() const { return connected; }

    bool resolveCollisions(std::vector<struct Asteroid>& pool, float dt, float restitution = 1.0f, float shipZ = 0.0f);

private:
    sock_t sock;
    bool   connected;

    bool sendAll(const char* p, int n) {
        while (n > 0) {
            int s = ::send(sock, p, n, 0);
            if (s <= 0) { disconnect(); return false; }
            p += s;
            n -= s;
        }
        return true;
    }

    bool recvAll(char* p, int n) {
        while (n > 0) {
            int r = ::recv(sock, p, n, 0);
            if (r <= 0) { disconnect(); return false; }
            p += r;
            n -= r;
        }
        return true;
    }
};

/*-------------------------------------------------------
  Constants and random helpers
-------------------------------------------------------*/

static const unsigned int SCR_WIDTH = 1280;
static const unsigned int SCR_HEIGHT = 720;

static std::mt19937_64 rng(
    (unsigned long long)std::chrono::high_resolution_clock::now().time_since_epoch().count()
);

static float randf(float a, float b) {
    std::uniform_real_distribution<float> d(a, b);
    return d(rng);
}

/*-------------------------------------------------------
  Perlin / FBM utilities
-------------------------------------------------------*/

namespace Perlin {
    static int  perm[512];
    static bool seeded = false;

    static void seed(unsigned int s) {
        std::mt19937 gen(s);
        for (int i = 0; i < 256; ++i) perm[i] = i;
        for (int i = 255; i > 0; --i) {
            int j = gen() % (i + 1);
            std::swap(perm[i], perm[j]);
        }
        for (int i = 0; i < 256; ++i) perm[256 + i] = perm[i];
        seeded = true;
    }

    static float fade(float t) { return t * t * t * (t * (t * 6 - 15) + 10); }
    static float lerp(float a, float b, float t) { return a + t * (b - a); }

    static float grad(int hash, float x, float y, float z) {
        int h = hash & 15;
        float u = h < 8 ? x : y;
        float v = h < 4 ? y : (h == 12 || h == 14 ? x : z);
        return ((h & 1) ? -u : u) + ((h & 2) ? -v : v);
    }

    static float noise(float x, float y, float z) {
        if (!seeded) seed(42);

        int X = (int)floorf(x) & 255;
        int Y = (int)floorf(y) & 255;
        int Z = (int)floorf(z) & 255;

        x -= floorf(x);
        y -= floorf(y);
        z -= floorf(z);

        float u = fade(x);
        float v = fade(y);
        float w = fade(z);

        int A = perm[X] + Y;
        int AA = perm[A] + Z;
        int AB = perm[A + 1] + Z;
        int B = perm[X + 1] + Y;
        int BA = perm[B] + Z;
        int BB = perm[B + 1] + Z;

        return lerp(
            lerp(
                lerp(grad(perm[AA], x, y, z), grad(perm[BA], x - 1, y, z), u),
                lerp(grad(perm[AB], x, y - 1, z), grad(perm[BB], x - 1, y - 1, z), u),
                v
            ),
            lerp(
                lerp(grad(perm[AA + 1], x, y, z - 1), grad(perm[BA + 1], x - 1, y, z - 1), u),
                lerp(grad(perm[AB + 1], x, y - 1, z - 1), grad(perm[BB + 1], x - 1, y - 1, z - 1), u),
                v
            ),
            w
        );
    }

    static float fbm(float x, float y, float z, int oct = 3) {
        float val = 0.0f;
        float amp = 0.5f;
        float freq = 1.0f;
        float mx = 0.0f;

        for (int i = 0; i < oct; ++i) {
            val += noise(x * freq, y * freq, z * freq) * amp;
            mx += amp;
            amp *= 0.5f;
            freq *= 2.1f;
        }

        return val / mx;
    }
}

/*-------------------------------------------------------
  Icosphere mesh generation helpers
-------------------------------------------------------*/

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

    addIcoVert(verts, { -1,  t,  0 });
    addIcoVert(verts, { 1,  t,  0 });
    addIcoVert(verts, { -1, -t,  0 });
    addIcoVert(verts, { 1, -t,  0 });

    addIcoVert(verts, { 0, -1,  t });
    addIcoVert(verts, { 0,  1,  t });
    addIcoVert(verts, { 0, -1, -t });
    addIcoVert(verts, { 0,  1, -t });

    addIcoVert(verts, { t,  0, -1 });
    addIcoVert(verts, { t,  0,  1 });
    addIcoVert(verts, { -t,  0, -1 });
    addIcoVert(verts, { -t,  0,  1 });

    faces = {
        {0,11,5}, {0,5,1}, {0,1,7},  {0,7,10}, {0,10,11},
        {1,5,9},  {5,11,4}, {11,10,2}, {10,7,6}, {7,1,8},
        {3,9,4},  {3,4,2},  {3,2,6},  {3,6,8},   {3,8,9},
        {4,9,5},  {2,4,11}, {6,2,10}, {8,6,7},   {9,8,1}
    };
}

static void subdivide(std::vector<IcoVert>& verts, std::vector<IcoFace>& faces) {
    std::vector<IcoFace> nf;
    nf.reserve(faces.size() * 4);

    for (auto& f : faces) {
        int ab = midpoint(verts, f.a, f.b);
        int bc = midpoint(verts, f.b, f.c);
        int ca = midpoint(verts, f.c, f.a);
        nf.push_back({ f.a, ab, ca });
        nf.push_back({ f.b, bc, ab });
        nf.push_back({ f.c, ca, bc });
        nf.push_back({ ab, bc, ca });
    }

    faces = nf;
}

struct Mesh {
    std::vector<float> verts;
    std::vector<unsigned int> indices;
};

static Mesh createAsteroid(unsigned int sub = 2, float ns = 1.8f, float na = 0.30f, unsigned int sd = 0) {
    Perlin::seed(sd);

    std::vector<IcoVert> verts;
    std::vector<IcoFace> faces;

    buildIcosahedron(verts, faces);

    for (unsigned int i = 0; i < sub; ++i) subdivide(verts, faces);

    for (auto& v : verts) {
        float n = Perlin::fbm(v.p.x * ns, v.p.y * ns, v.p.z * ns, 3);
        v.p *= (1.0f + n * na);
    }

    Mesh m;
    m.verts.reserve(faces.size() * 3 * 6);

    for (auto& f : faces) {
        glm::vec3 A = verts[f.a].p;
        glm::vec3 B = verts[f.b].p;
        glm::vec3 C = verts[f.c].p;
        glm::vec3 n = glm::normalize(glm::cross(B - A, C - A));

        for (auto& p : { A, B, C }) {
            m.verts.push_back(p.x);
            m.verts.push_back(p.y);
            m.verts.push_back(p.z);
            m.verts.push_back(n.x);
            m.verts.push_back(n.y);
            m.verts.push_back(n.z);
        }
    }

    return m;
}

/*-------------------------------------------------------
  Cube vertex data
-------------------------------------------------------*/

static const float cubeVerts[] = {
    -0.5f,-0.5f,-0.5f, 0,0,-1,  0.5f,0.5f,-0.5f, 0,0,-1,  0.5f,-0.5f,-0.5f, 0,0,-1,
     0.5f,0.5f,-0.5f, 0,0,-1, -0.5f,-0.5f,-0.5f, 0,0,-1, -0.5f,0.5f,-0.5f, 0,0,-1,
    -0.5f,-0.5f, 0.5f, 0,0, 1,  0.5f,-0.5f, 0.5f, 0,0, 1,  0.5f,0.5f, 0.5f, 0,0, 1,
     0.5f,0.5f, 0.5f, 0,0, 1, -0.5f,0.5f, 0.5f, 0,0, 1, -0.5f,-0.5f,0.5f, 0,0, 1,
    -0.5f,0.5f, 0.5f,-1,0, 0, -0.5f,0.5f,-0.5f,-1,0, 0, -0.5f,-0.5f,-0.5f,-1,0,0,
    -0.5f,-0.5f,-0.5f,-1,0,0, -0.5f,-0.5f,0.5f,-1,0,0, -0.5f,0.5f,0.5f,-1,0,0,
     0.5f,0.5f,0.5f, 1,0,0, 0.5f,-0.5f,-0.5f, 1,0,0, 0.5f,0.5f,-0.5f, 1,0,0,
     0.5f,-0.5f,-0.5f,1,0,0,  0.5f,0.5f,0.5f, 1,0,0,  0.5f,-0.5f,0.5f, 1,0,0,
    -0.5f,-0.5f,-0.5f,0,-1,0, 0.5f,-0.5f,-0.5f,0,-1,0, 0.5f,-0.5f,0.5f,0,-1,0,
     0.5f,-0.5f,0.5f,0,-1,0, -0.5f,-0.5f,0.5f,0,-1,0, -0.5f,-0.5f,-0.5f,0,-1,0,
    -0.5f,0.5f,-0.5f,0,1,0, 0.5f,0.5f,0.5f,0,1,0, 0.5f,0.5f,-0.5f,0,1,0,
     0.5f,0.5f,0.5f,0,1,0, -0.5f,0.5f,-0.5f,0,1,0, -0.5f,0.5f,0.5f,0,1,0
};

/*-------------------------------------------------------
  Game / physics structures
-------------------------------------------------------*/

struct Asteroid {
    glm::vec3 pos, vel;
    float     radius;
    glm::vec3 axis;
    float     angle, rotSpeed;
    glm::vec3 tint;
    unsigned int meshSeed;
};

/*-------------------------------------------------------
  ColFPGA::resolveCollisions implementation
-------------------------------------------------------*/

bool ColFPGA::resolveCollisions(std::vector<Asteroid>& pool, float dt, float restitution, float shipZ) {
    if (!connected) return false;

    int n = (int)pool.size();
    if (n <= 0 || n > 256) return false;

    std::vector<ColRecord> send_buf(n);
    for (int i = 0; i < n; ++i) {
        send_buf[i].px = f2q(pool[i].pos.x);
        send_buf[i].py = f2q(pool[i].pos.y);
        send_buf[i].pz = f2q(pool[i].pos.z - shipZ);
        send_buf[i].vx = f2q(pool[i].vel.x);
        send_buf[i].vy = f2q(pool[i].vel.y);
        send_buf[i].vz = f2q(pool[i].vel.z);
        send_buf[i].radius = f2q(pool[i].radius);
        float r = pool[i].radius;
        send_buf[i].mass = f2q(r * r * r);
    }

    uint32_t hdr[3] = { (uint32_t)n, f2qu(dt), f2qu(restitution) };

    if (!sendAll((char*)hdr, 12)) return false;
    if (!sendAll((char*)send_buf.data(), n * 32)) return false;

    std::vector<ColRecord> recv_buf(n);
    if (!recvAll((char*)recv_buf.data(), n * 32)) return false;

    for (int i = 0; i < n; ++i) {
        pool[i].pos.x = q2f(recv_buf[i].px);
        pool[i].pos.y = q2f(recv_buf[i].py);
        pool[i].pos.z = q2f(recv_buf[i].pz) + shipZ;
        pool[i].vel.x = q2f(recv_buf[i].vx);
        pool[i].vel.y = q2f(recv_buf[i].vy);
        pool[i].vel.z = q2f(recv_buf[i].vz);
    }

    return true;
}

/*-------------------------------------------------------
  Collision engine + renderer (trimmed formatting)
-------------------------------------------------------*/

class CollisionEngine {
public:
    CollisionEngine(int n = 75)
        : ASTEROID_COUNT(n),
        shipPos(0, 0, 0),
        shipVel(0),
        shipSpeed(12.0f),
        shipRadius(0.6f),
        gameOver(false),
        fpga(nullptr)
    {
        pool.reserve(ASTEROID_COUNT);
        initPool();
    }

    void setFPGA(ColFPGA* f) { fpga = f; }

    void reset() {
        shipPos = glm::vec3(0, 0, 0);
        shipVel = glm::vec3(0, 0, 0);
        gameOver = false;
        initPool();
    }

    void update(float dt, float lat, float vert) {
        if (gameOver) return;

        glm::vec3 desired = glm::vec3(lat * shipSpeed, vert * shipSpeed, 0.0f);
        shipVel = glm::mix(shipVel, desired, glm::clamp(6.0f * dt, 0.0f, 1.0f));
        shipPos += shipVel * dt;
        shipPos.x = glm::clamp(shipPos.x, -X_LIMIT, X_LIMIT);
        shipPos.y = glm::clamp(shipPos.y, -Y_LIMIT, Y_LIMIT);

        for (auto& a : pool) a.angle += a.rotSpeed * dt;

        bool usedFPGA = false;
        if (fpga && fpga->isConnected()) {
            usedFPGA = fpga->resolveCollisions(pool, dt, 1.0f, shipPos.z);
            if (!usedFPGA) std::cerr << "[FPGA] frame failed\n";
        }

        if (!usedFPGA) { for (auto& a : pool)a.pos += a.vel * dt; resolveAsteroidCollisions();
        } // CPU fallback! disable to see whether the fpga is truly doing the calculations and kill the server :)

        for (auto& a : pool) {
            if (glm::length(shipPos - a.pos) < shipRadius + a.radius) {
                gameOver = true;
                return;
            }
        }

        for (auto& a : pool) {
            if (a.pos.z > shipPos.z + 8.0f) spawnAsteroid(a);
        }
    }

    const std::vector<Asteroid>& getPool() const { return pool; }
    const glm::vec3& getShipPos() const { return shipPos; }
    const glm::vec3& getShipVel() const { return shipVel; }
    float getShipRadius() const { return shipRadius; }
    bool isGameOver() const { return gameOver; }

private:
    const int ASTEROID_COUNT;
    const float X_LIMIT = 18.0f, Y_LIMIT = 9.0f;

    glm::vec3 shipPos, shipVel;
    float shipSpeed, shipRadius;
    bool gameOver;

    std::vector<Asteroid> pool;
    glm::vec3 asteroidBase = glm::vec3(0.42f, 0.40f, 0.36f);

    ColFPGA* fpga;

    void initPool() {
        pool.clear();
        for (int i = 0; i < ASTEROID_COUNT; ++i) {
            Asteroid a;
            spawnAsteroid(a);
            pool.push_back(a);
        }
    }

    void spawnAsteroid(Asteroid& a) {
        a.radius = randf(0.8f, 2.0f);
        a.pos = glm::vec3(randf(-14, 14), randf(-7, 7), shipPos.z - randf(20, 100));
        a.vel = glm::vec3(randf(-0.8f, 0.8f), randf(-0.6f, 0.6f), randf(5, 12));
        a.axis = glm::normalize(glm::vec3(randf(-1, 1), randf(-1, 1), randf(-1, 1)));
        a.angle = randf(0, 360);
        a.rotSpeed = randf(-60, 60);
        a.tint = glm::vec3(randf(-0.06f, 0.06f), randf(-0.05f, 0.05f), randf(-0.04f, 0.04f));
        a.meshSeed = (unsigned int)(rng() & 0xFFFFFFFF);
    }

    void resolveAsteroidCollisions() {
        const float EPS = 1e-5f;
        const float restitution = 1.0f;
        int n = (int)pool.size();

        for (int i = 0; i < n; ++i) {
            for (int j = i + 1; j < n; ++j) {
                Asteroid& A = pool[i];
                Asteroid& B = pool[j];

                glm::vec3 dp = A.pos - B.pos;
                float dist2 = glm::dot(dp, dp);
                float rSum = A.radius + B.radius;

                if (dist2 > rSum * rSum) continue;

                float dist = sqrtf(dist2 > EPS ? dist2 : EPS);
                glm::vec3 nrm = dp / dist;
                if (!std::isfinite(nrm.x)) {
                    nrm = glm::normalize(glm::vec3(randf(-1, 1), randf(-1, 1), randf(-1, 1)));
                }

                float mA = A.radius * A.radius * A.radius;
                float mB = B.radius * B.radius * B.radius;

                float relVel = glm::dot(A.vel - B.vel, nrm);
                if (relVel < 0.0f) {
                    float j2 = -(1.0f + restitution) * relVel / (1.0f / mA + 1.0f / mB);
                    glm::vec3 imp = j2 * nrm;
                    A.vel += imp / mA;
                    B.vel -= imp / mB;
                }

                float pen = rSum - dist;
                if (pen > 0.0f) {
                    glm::vec3 corr = (pen / (mA + mB)) * 0.8f * nrm;
                    A.pos += corr * mB;
                    B.pos -= corr * mA;
                }
            }
        }
    }
};

/*-------------------------------------------------------
  Renderer (OpenGL) — shaders kept as raw strings
-------------------------------------------------------*/

class Renderer {
public:
    Renderer(const CollisionEngine& physicsRef)
        : physics(physicsRef),
        cameraOffset(0, 1.6f, 6.5f),
        camPosPrev(physicsRef.getShipPos() + glm::vec3(0, 1.6f, 6.5f)),
        fov(62.0f)
    {
        glEnable(GL_DEPTH_TEST);
        glEnable(GL_CULL_FACE);
        glCullFace(GL_BACK);
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

        glDeleteVertexArrays(1, &cubeVAO);
        glDeleteBuffers(1, &cubeVBO);

        glDeleteVertexArrays(1, &starVAO);
        glDeleteBuffers(1, &starVBO);

        glDeleteVertexArrays(1, &overlayVAO);
        glDeleteBuffers(1, &overlayVBO);

        for (auto& v : asteroidVAOs) glDeleteVertexArrays(1, &v);
        for (auto& v : asteroidVBOs) glDeleteBuffers(1, &v);
    }

    void render(float dt) {
        const glm::vec3 shipPos = physics.getShipPos();
        camPosPrev = glm::mix(camPosPrev, shipPos + cameraOffset, glm::clamp(8.0f * dt, 0.0f, 1.0f));

        glm::vec3 camPos = camPosPrev;
        glm::vec3 camLook = shipPos + glm::vec3(0, 0.35f, 0);

        glm::mat4 view = glm::lookAt(camPos, camLook, glm::vec3(0, 1, 0));
        glm::mat4 proj = glm::perspective(glm::radians(fov), (float)SCR_WIDTH / SCR_HEIGHT, 0.1f, 2000.0f);

        glClearColor(fogColor.r, fogColor.g, fogColor.b, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        // Stars
        glUseProgram(starProg);
        glUniformMatrix4fv(glGetUniformLocation(starProg, "view"), 1, GL_FALSE, glm::value_ptr(view));
        glUniformMatrix4fv(glGetUniformLocation(starProg, "projection"), 1, GL_FALSE, glm::value_ptr(proj));
        glBindVertexArray(starVAO);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE);
        glDepthMask(GL_FALSE);
        glDrawArrays(GL_POINTS, 0, STAR_COUNT);
        glDepthMask(GL_TRUE);
        glDisable(GL_BLEND);

        // Objects
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

        float roll = glm::clamp(-physics.getShipVel().x * 0.02f, -0.25f, 0.25f);

        glm::mat4 sm(1);
        sm = glm::translate(sm, shipPos);
        sm = glm::rotate(sm, roll, glm::vec3(0, 0, 1));
        sm = glm::scale(sm, glm::vec3(1.0f, 0.48f, 1.8f));

        glUniformMatrix4fv(glGetUniformLocation(objProg, "model"), 1, GL_FALSE, glm::value_ptr(sm));
        glUniform3f(glGetUniformLocation(objProg, "objectColor"), shipColor.r, shipColor.g, shipColor.b);

        glBindVertexArray(cubeVAO);
        glDrawArrays(GL_TRIANGLES, 0, 36);

        const auto& pool = physics.getPool();
        for (int i = 0; i < (int)pool.size(); ++i) {
            const auto& a = pool[i];
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
    std::vector<GLuint> asteroidVAOs, asteroidVBOs;
    std::vector<GLsizei> asteroidVertCounts;
    std::vector<unsigned int> asteroidSeeds;

    glm::vec3 cameraOffset, camPosPrev;
    float fov;

    glm::vec3 lightDir, fogColor, shipColor, asteroidBase;
    float ambient, shininess, fogStart, fogEnd;

    // Shaders (raw strings kept intact)
    static constexpr const char* objVert = R"glsl(
    #version 330 core
    layout(location=0)in vec3 aPos;layout(location=1)in vec3 aNormal;
    out vec3 FragPos;out vec3 Normal;uniform mat4 model,view,projection;
    void main(){FragPos=vec3(model*vec4(aPos,1.0));Normal=mat3(transpose(inverse(model)))*aNormal;gl_Position=projection*view*vec4(FragPos,1.0);})glsl";

    static constexpr const char* objFrag = R"glsl(
    #version 330 core
    in vec3 FragPos;in vec3 Normal;out vec4 FragColor;
    uniform vec3 objectColor,lightDir,viewPos,fogColor;uniform float ambientStrength,shininess,fogStart,fogEnd;
    void main(){
        vec3 n=normalize(Normal);float diff=max(dot(n,lightDir),0.0);
        vec3 viewDir=normalize(viewPos-FragPos);vec3 rD=reflect(-lightDir,n);
        float spec=pow(max(dot(viewDir,rD),0.0),shininess);
        vec3 result=(ambientStrength+diff+0.3*spec)*objectColor;
        float dist=length(viewPos-FragPos);float fog=clamp((dist-fogStart)/(fogEnd-fogStart),0.0,1.0);
        FragColor=vec4(mix(result,fogColor,fog),1.0);})glsl";

    static constexpr const char* starVert = R"glsl(
    #version 330 core
    layout(location=0)in vec3 aPos;layout(location=1)in float aBrightness;
    uniform mat4 view,projection;out float Brightness;
    void main(){Brightness=aBrightness;gl_Position=projection*view*vec4(aPos,1.0);gl_PointSize=max(1.0,2.5*aBrightness);})glsl";

    static constexpr const char* starFrag = R"glsl(
    #version 330 core
    in float Brightness;out vec4 FragColor;
    void main(){FragColor=vec4(vec3(Brightness),0.85);})glsl";

    static constexpr const char* overlayVert = R"glsl(
    #version 330 core
    layout(location=0)in vec2 aPos;out vec2 TexCoord;
    void main(){TexCoord=aPos*0.5+0.5;gl_Position=vec4(aPos,0,1);})glsl";

    // Bitmap font: 5 wide x 7 tall pixels per glyph (overlayFrag raw).
    static constexpr const char* overlayFrag = R"glsl(
    #version 330 core
    in vec2 TexCoord;out vec4 FragColor;

    int getRow(int c, int r){
      if(c==32) return 0;
      // A  .XXX. X...X X...X XXXXX X...X X...X X...X
      if(c==65){if(r==0)return 14;if(r==1)return 17;if(r==2)return 17;if(r==3)return 31;if(r==4)return 17;if(r==5)return 17;if(r==6)return 17;return 0;}
      // C  .XXX. X...X X.... X.... X.... X...X .XXX.
      if(c==67){if(r==0)return 14;if(r==1)return 17;if(r==2)return 1;if(r==3)return 1;if(r==4)return 1;if(r==5)return 17;if(r==6)return 14;return 0;}
      // E  XXXXX X.... X.... XXXX. X.... X.... XXXXX
      if(c==69){if(r==0)return 31;if(r==1)return 1;if(r==2)return 1;if(r==3)return 15;if(r==4)return 1;if(r==5)return 1;if(r==6)return 31;return 0;}
      // G  .XXX. X...X X.... X.XXX X...X X...X .XXX.
      if(c==71){if(r==0)return 14;if(r==1)return 17;if(r==2)return 1;if(r==3)return 29;if(r==4)return 17;if(r==5)return 17;if(r==6)return 14;return 0;}
      // M  X...X XX.XX X.X.X X...X X...X X...X X...X
      if(c==77){if(r==0)return 17;if(r==1)return 27;if(r==2)return 21;if(r==3)return 17;if(r==4)return 17;if(r==5)return 17;if(r==6)return 17;return 0;}
      // O  .XXX. X...X X...X X...X X...X X...X .XXX.
      if(c==79){if(r==0)return 14;if(r==1)return 17;if(r==2)return 17;if(r==3)return 17;if(r==4)return 17;if(r==5)return 17;if(r==6)return 14;return 0;}
      // P  XXXX. X...X X...X XXXX. X.... X.... X....
      if(c==80){if(r==0)return 15;if(r==1)return 17;if(r==2)return 17;if(r==3)return 15;if(r==4)return 1;if(r==5)return 1;if(r==6)return 1;return 0;}
      // R  XXXX. X...X X...X XXXX. X.X.. X..X. X...X
      if(c==82){if(r==0)return 15;if(r==1)return 17;if(r==2)return 17;if(r==3)return 15;if(r==4)return 5;if(r==5)return 9;if(r==6)return 17;return 0;}
      // S  .XXXX X.... X.... .XXX. ....X ....X XXXX.
      if(c==83){if(r==0)return 30;if(r==1)return 1;if(r==2)return 1;if(r==3)return 14;if(r==4)return 16;if(r==5)return 16;if(r==6)return 15;return 0;}
      // T  XXXXX ..X.. ..X.. ..X.. ..X.. ..X.. ..X..
      if(c==84){if(r==0)return 31;if(r==1)return 4;if(r==2)return 4;if(r==3)return 4;if(r==4)return 4;if(r==5)return 4;if(r==6)return 4;return 0;}
      // V  X...X X...X X...X X...X X...X .X.X. ..X..
      if(c==86){if(r==0)return 17;if(r==1)return 17;if(r==2)return 17;if(r==3)return 17;if(r==4)return 17;if(r==5)return 10;if(r==6)return 4;return 0;}
      return 0;
    }

    // Sample character c at UV [0,1]^2 (row 0 = top)
    float sampleGlyph(int c, vec2 uv){
        if(uv.x<0.0||uv.x>=1.0||uv.y<0.0||uv.y>=1.0)return 0.0;
        int col = int(uv.x * 5.0);
        int row = int((1.0 - uv.y) * 7.0);
        col = clamp(col,0,4); row = clamp(row,0,6);
        int rowBits = getRow(c, row);
        return float((rowBits >> col) & 1);
    }

    void main(){
        vec2 pixel = TexCoord * vec2(1280.0,720.0);

        // "GAME OVER"
        float CW1=44.0, CH1=62.0;
        float x1=(1280.0-9.0*CW1)*0.5;
        float y1=720.0*0.5-CH1-16.0;
        int go[9]; go[0]=71;go[1]=65;go[2]=77;go[3]=69;go[4]=32;go[5]=79;go[6]=86;go[7]=69;go[8]=82;
        float h1=0.0;
        for(int i=0;i<9;i++){
            vec2 uv=(pixel-vec2(x1+float(i)*CW1,y1))/vec2(CW1,CH1);
            h1=max(h1,sampleGlyph(go[i],uv));
        }

        // "PRESS SPACE TO RESTART"
        float CW2=28.0, CH2=40.0;
        float x2=(1280.0-22.0*CW2)*0.5;
        float y2=720.0*0.5+16.0;
        int ps[22];ps[0]=80;ps[1]=82;ps[2]=69;ps[3]=83;ps[4]=83;ps[5]=32;ps[6]=83;ps[7]=80;ps[8]=65;ps[9]=67;ps[10]=69;ps[11]=32;ps[12]=84;ps[13]=79;ps[14]=32;ps[15]=82;ps[16]=69;ps[17]=83;ps[18]=84;ps[19]=65;ps[20]=82;ps[21]=84;
        float h2=0.0;
        for(int i=0;i<22;i++){
            vec2 uv=(pixel-vec2(x2+float(i)*CW2,y2))/vec2(CW2,CH2);
            h2=max(h2,sampleGlyph(ps[i],uv));
        }

        vec4 bg=vec4(0.0,0.0,0.0,0.6);
        vec4 col=bg;
        if(h1>0.5) col=vec4(1.0,0.25,0.12,1.0);
        if(h2>0.5) col=vec4(0.95,0.95,0.95,1.0);
        FragColor=col;
    })glsl";

    static GLuint compileLinkProgram(const char* vsSrc, const char* fsSrc) {
        auto compile = [](GLenum t, const char* src)->GLuint {
            GLuint s = glCreateShader(t);
            glShaderSource(s, 1, &src, nullptr);
            glCompileShader(s);
            GLint ok; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
            if (!ok) {
                GLint len = 0;
                glGetShaderiv(s, GL_INFO_LOG_LENGTH, &len);
                std::vector<char> buf(len + 1);
                glGetShaderInfoLog(s, len, nullptr, buf.data());
                std::cerr << "Shader error: " << buf.data() << "\n";
            }
            return s;
            };

        GLuint vs = compile(GL_VERTEX_SHADER, vsSrc);
        GLuint fs = compile(GL_FRAGMENT_SHADER, fsSrc);
        GLuint p = glCreateProgram();

        glAttachShader(p, vs);
        glAttachShader(p, fs);
        glLinkProgram(p);

        GLint ok; glGetProgramiv(p, GL_LINK_STATUS, &ok);
        if (!ok) {
            GLint len = 0;
            glGetProgramiv(p, GL_INFO_LOG_LENGTH, &len);
            std::vector<char> buf(len + 1);
            glGetProgramInfoLog(p, len, nullptr, buf.data());
            std::cerr << "Link error: " << buf.data() << "\n";
        }

        glDeleteShader(vs);
        glDeleteShader(fs);
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
        glGenVertexArrays(1, &vao);
        glGenBuffers(1, &vbo);

        glBindVertexArray(vao);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, m.verts.size() * sizeof(float), m.verts.data(), GL_STATIC_DRAW);

        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), (void*)0);
        glEnableVertexAttribArray(0);

        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), (void*)(3 * sizeof(float)));
        glEnableVertexAttribArray(1);

        glBindVertexArray(0);

        asteroidVAOs[idx] = vao;
        asteroidVBOs[idx] = vbo;
        asteroidVertCounts[idx] = (GLsizei)(m.verts.size() / 6);
        asteroidSeeds[idx] = seed;
    }

    void setupMeshes() {
        glGenVertexArrays(1, &cubeVAO);
        glGenBuffers(1, &cubeVBO);

        glBindVertexArray(cubeVAO);
        glBindBuffer(GL_ARRAY_BUFFER, cubeVBO);
        glBufferData(GL_ARRAY_BUFFER, sizeof(cubeVerts), cubeVerts, GL_STATIC_DRAW);

        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), (void*)0);
        glEnableVertexAttribArray(0);

        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), (void*)(3 * sizeof(float)));
        glEnableVertexAttribArray(1);

        glBindVertexArray(0);
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

        glGenVertexArrays(1, &starVAO);
        glGenBuffers(1, &starVBO);

        glBindVertexArray(starVAO);
        glBindBuffer(GL_ARRAY_BUFFER, starVBO);
        glBufferData(GL_ARRAY_BUFFER, stars.size() * sizeof(float), stars.data(), GL_STATIC_DRAW);

        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);
        glEnableVertexAttribArray(0);

        glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(3 * sizeof(float)));
        glEnableVertexAttribArray(1);

        glBindVertexArray(0);
    }

    void setupOverlay() {
        float quad[] = { -1,-1, 1,-1, 1,1, -1,-1, 1,1, -1,1 };
        glGenVertexArrays(1, &overlayVAO);
        glGenBuffers(1, &overlayVBO);

        glBindVertexArray(overlayVAO);
        glBindBuffer(GL_ARRAY_BUFFER, overlayVBO);
        glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);

        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float), (void*)0);
        glEnableVertexAttribArray(0);

        glBindVertexArray(0);
    }

    void renderOverlay() {
        glDisable(GL_DEPTH_TEST);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

        glUseProgram(overlayProg);
        glBindVertexArray(overlayVAO);
        glDrawArrays(GL_TRIANGLES, 0, 6);

        glDisable(GL_BLEND);
        glEnable(GL_DEPTH_TEST);
    }
};

/*-------------------------------------------------------
  Input handling and main()
-------------------------------------------------------*/

bool keys[1024] = {};
bool prevKeys[1024] = {};

void key_callback(GLFWwindow* w, int key, int sc, int action, int mods) {
    if (key == GLFW_KEY_ESCAPE && action == GLFW_PRESS) glfwSetWindowShouldClose(w, GLFW_TRUE);
    if (key >= 0 && key < 1024) {
        if (action == GLFW_PRESS)      keys[key] = true;
        else if (action == GLFW_RELEASE) keys[key] = false;
    }
}

void framebuffer_size_callback(GLFWwindow*, int w, int h) {
    glViewport(0, 0, w, h);
}

int main() {
    glfwInit();
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);

    GLFWwindow* window = glfwCreateWindow(SCR_WIDTH, SCR_HEIGHT, "Asteroids [FPGA]", nullptr, nullptr);
    if (!window) {
        std::cerr << "Failed to create window\n";
        glfwTerminate();
        return -1;
    }

    glfwMakeContextCurrent(window);
    glfwSetFramebufferSizeCallback(window, framebuffer_size_callback);
    glfwSetKeyCallback(window, key_callback);

    if (!gladLoadGLLoader((GLADloadproc)glfwGetProcAddress)) {
        std::cerr << "GLAD init failed\n";
        return -1;
    }

    ColFPGA fpga;
    if (fpga.connect("192.168.2.99", 5005))
        std::cout << "[FPGA] Collision offloading ACTIVE\n";
    else
        std::cout << "[FPGA] Not reachable — using CPU fallback\n";

    CollisionEngine physics(100);
    physics.setFPGA(&fpga);

    Renderer renderer(physics);

    double lastTime = glfwGetTime();

    while (!glfwWindowShouldClose(window)) {
        double now = glfwGetTime();
        float dt = (float)(now - lastTime);
        lastTime = now;
        if (dt <= 0.0f) dt = 0.001f;

        if (physics.isGameOver() && keys[GLFW_KEY_SPACE] && !prevKeys[GLFW_KEY_SPACE])
            physics.reset();

        memcpy(prevKeys, keys, sizeof(keys));

        float lat = 0, vert = 0;
        if (!physics.isGameOver()) {
            if (keys[GLFW_KEY_A]) lat -= 1;
            if (keys[GLFW_KEY_D]) lat += 1;
            if (keys[GLFW_KEY_W]) vert += 1;
            if (keys[GLFW_KEY_S]) vert -= 1;
        }

        physics.update(dt, lat, vert);
        renderer.render(dt);

        glfwSwapBuffers(window);
        glfwPollEvents();
    }

    glfwDestroyWindow(window);
    glfwTerminate();
    return 0;
}