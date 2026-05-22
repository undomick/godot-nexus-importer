// Nexus B2G shared shader include.
vec3 nexus_rotate_around_axis(vec3 p, vec3 axis, float angle)
{
	float costheta = cos(angle);
	float sintheta = sin(angle);
	vec3 r;
	r.x = ((costheta + (1.0 - costheta) * axis.x * axis.x) * p.x) +
		(((1.0 - costheta) * axis.x * axis.y - axis.z * sintheta) * p.y) +
		(((1.0 - costheta) * axis.x * axis.z + axis.y * sintheta) * p.z);
	r.y = (((1.0 - costheta) * axis.x * axis.y + axis.z * sintheta) * p.x) +
		((costheta + (1.0 - costheta) * axis.y * axis.y) * p.y) +
		(((1.0 - costheta) * axis.y * axis.z - axis.x * sintheta) * p.z);
	r.z = (((1.0 - costheta) * axis.x * axis.z - axis.y * sintheta) * p.x) +
		(((1.0 - costheta) * axis.y * axis.z + axis.x * sintheta) * p.y) +
		((costheta + (1.0 - costheta) * axis.z * axis.z) * p.z);
	return r;
}
