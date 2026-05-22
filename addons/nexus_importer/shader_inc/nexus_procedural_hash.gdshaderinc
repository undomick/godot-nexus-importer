// Nexus B2G shared shader include.
uint nexus_hash_rot(uint x, int k) {
	return (x << uint(k)) | (x >> uint(32 - k));
}

void nexus_hash_mix(inout uint a, inout uint b, inout uint c) {
	a -= c;
	a ^= nexus_hash_rot(c, 4);
	c += b;
	b -= a;
	b ^= nexus_hash_rot(a, 6);
	a += c;
	c -= b;
	c ^= nexus_hash_rot(b, 8);
	b += a;
	a -= c;
	a ^= nexus_hash_rot(c, 16);
	c += b;
	b -= a;
	b ^= nexus_hash_rot(a, 19);
	a += c;
	c -= b;
	c ^= nexus_hash_rot(b, 4);
	b += a;
}

void nexus_hash_final(inout uint a, inout uint b, inout uint c) {
	c ^= b;
	c -= nexus_hash_rot(b, 14);
	a ^= c;
	a -= nexus_hash_rot(c, 11);
	b ^= a;
	b -= nexus_hash_rot(a, 25);
	c ^= b;
	c -= nexus_hash_rot(b, 16);
	a ^= c;
	a -= nexus_hash_rot(c, 4);
	b ^= a;
	b -= nexus_hash_rot(a, 14);
	c ^= b;
	c -= nexus_hash_rot(b, 24);
}

uint hash_uint(uint kx) {
	uint a, b, c;
	a = b = c = 0xdeadbeefu + (1u << 2u) + 13u;
	a += kx;
	nexus_hash_final(a, b, c);
	return c;
}

uint hash_uint2(uint kx, uint ky) {
	uint a, b, c;
	a = b = c = 0xdeadbeefu + (2u << 2u) + 13u;
	b += ky;
	a += kx;
	nexus_hash_final(a, b, c);
	return c;
}

uint hash_uint3(uint kx, uint ky, uint kz) {
	uint a, b, c;
	a = b = c = 0xdeadbeefu + (3u << 2u) + 13u;
	c += kz;
	b += ky;
	a += kx;
	nexus_hash_final(a, b, c);
	return c;
}

uint hash_uint4(uint kx, uint ky, uint kz, uint kw) {
	uint a, b, c;
	a = b = c = 0xdeadbeefu + (4u << 2u) + 13u;
	a += kx;
	b += ky;
	c += kz;
	nexus_hash_mix(a, b, c);
	a += kw;
	nexus_hash_final(a, b, c);
	return c;
}

uint hash_int(int kx) { return hash_uint(uint(kx)); }
uint hash_int2(int kx, int ky) { return hash_uint2(uint(kx), uint(ky)); }
uint hash_int3(int kx, int ky, int kz) { return hash_uint3(uint(kx), uint(ky), uint(kz)); }
uint hash_int4(int kx, int ky, int kz, int kw) {
	return hash_uint4(uint(kx), uint(ky), uint(kz), uint(kw));
}

ivec2 hash_pcg2d_i(ivec2 v) {
	v = v * 1664525 + 1013904223;
	v.x += v.y * 1664525;
	v.y += v.x * 1664525;
	v = v ^ (v >> 16);
	v.x += v.y * 1664525;
	v.y += v.x * 1664525;
	return v;
}

ivec3 hash_pcg3d_i(ivec3 v) {
	v = v * 1664525 + 1013904223;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v = v ^ (v >> 16);
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	return v;
}

ivec4 hash_pcg4d_i(ivec4 v) {
	v = v * 1664525 + 1013904223;
	v.x += v.y * v.w;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v.w += v.y * v.z;
	v = v ^ (v >> 16);
	v.x += v.y * v.w;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v.w += v.y * v.z;
	return v;
}

float hash_uint_to_float(uint kx) { return float(hash_uint(kx)) / float(0xFFFFFFFFu); }
float hash_uint2_to_float(uint kx, uint ky) { return float(hash_uint2(kx, ky)) / float(0xFFFFFFFFu); }
float hash_uint3_to_float(uint kx, uint ky, uint kz) {
	return float(hash_uint3(kx, ky, kz)) / float(0xFFFFFFFFu);
}
float hash_uint4_to_float(uint kx, uint ky, uint kz, uint kw) {
	return float(hash_uint4(kx, ky, kz, kw)) / float(0xFFFFFFFFu);
}

float hash_float_to_float(float k) { return hash_uint_to_float(floatBitsToUint(k)); }
float hash_vec2_to_float(vec2 k) {
	return hash_uint2_to_float(floatBitsToUint(k.x), floatBitsToUint(k.y));
}
float hash_vec3_to_float(vec3 k) {
	return hash_uint3_to_float(floatBitsToUint(k.x), floatBitsToUint(k.y), floatBitsToUint(k.z));
}
float hash_vec4_to_float(vec4 k) {
	return hash_uint4_to_float(
		floatBitsToUint(k.x), floatBitsToUint(k.y), floatBitsToUint(k.z), floatBitsToUint(k.w));
}

vec2 hash_vec2_to_vec2(vec2 k) {
	return vec2(hash_vec2_to_float(k), hash_vec3_to_float(vec3(k, 1.0)));
}
vec3 hash_vec3_to_vec3(vec3 k) {
	return vec3(
		hash_vec3_to_float(k), hash_vec4_to_float(vec4(k, 1.0)), hash_vec4_to_float(vec4(k, 2.0)));
}
vec4 hash_vec4_to_vec4(vec4 k) {
	return vec4(
		hash_vec4_to_float(k.xyzw), hash_vec4_to_float(k.wxyz),
		hash_vec4_to_float(k.zwxy), hash_vec4_to_float(k.yzwx));
}

vec2 hash_int2_to_vec2(ivec2 k) {
	ivec2 h = hash_pcg2d_i(k);
	return vec2(float(h.x & 0x7fffffff), float(h.y & 0x7fffffff)) * (1.0 / float(0x7fffffff));
}
vec3 hash_int3_to_vec3(ivec3 k) {
	ivec3 h = hash_pcg3d_i(k);
	return vec3(float(h.x & 0x7fffffff), float(h.y & 0x7fffffff), float(h.z & 0x7fffffff)) * (1.0 / float(0x7fffffff));
}
vec4 hash_int4_to_vec4(ivec4 k) {
	ivec4 h = hash_pcg4d_i(k);
	return vec4(float(h.x & 0x7fffffff), float(h.y & 0x7fffffff), float(h.z & 0x7fffffff), float(h.w & 0x7fffffff)) * (1.0 / float(0x7fffffff));
}
vec3 hash_int2_to_vec3(ivec2 k) { return hash_int3_to_vec3(ivec3(k.x, k.y, 0)); }
vec3 hash_int4_to_vec3(ivec4 k) { return hash_int4_to_vec4(k).xyz; }

vec3 hash_float_to_vec3(float k) {
	return vec3(hash_float_to_float(k), hash_vec2_to_float(vec2(k, 1.0)), hash_vec2_to_float(vec2(k, 2.0)));
}
vec3 hash_vec2_to_vec3(vec2 k) {
	return vec3(hash_vec2_to_float(k), hash_vec3_to_float(vec3(k, 1.0)), hash_vec3_to_float(vec3(k, 2.0)));
}
vec3 hash_vec4_to_vec3(vec4 k) {
	return vec3(
		hash_vec4_to_float(k.xyzw), hash_vec4_to_float(k.zxwy), hash_vec4_to_float(k.wzyx));
}
vec2 hash_float_to_vec2(float k) {
	return vec2(hash_float_to_float(k), hash_vec2_to_float(vec2(k, 1.0)));
}
vec2 hash_vec3_to_vec2(vec3 k) {
	return vec2(hash_vec3_to_float(k.xyz), hash_vec3_to_float(k.zxy));
}
vec2 hash_vec4_to_vec2(vec4 k) {
	return vec2(hash_vec4_to_float(k.xyzw), hash_vec4_to_float(k.zxwy));
}

float integer_noise(int n) {
	uint nn = (uint(n) + 1013u) & 0x7fffffffu;
	nn = (nn >> 13u) ^ nn;
	nn = (uint(nn * (nn * nn * 60493u + 19990303u)) + 1376312589u) & 0x7fffffffu;
	return 0.5 * (float(nn) / 1073741824.0);
}

float wang_hash_noise(uint s) {
	s = (s ^ 61u) ^ (s >> 16u);
	s *= 9u;
	s = s ^ (s >> 4u);
	s *= 0x27d4eb2du;
	s = s ^ (s >> 15u);
	return fract(float(s) / 4294967296.0);
}
