#define MAKE_STRING(...) #__VA_ARGS__
R"(
#version 400 core
#define Kconstant  K[0]
#define Klinear    K[1]
#define Kquadratic K[2]
#define MAX_POINT_LIGHTS 2
#define MAX_SPOT_LIGHTS 8
#define MAX_DIR_LIGHTS 2
#define POINT_LIGHT_SAMPLES 20
)" \
MAKE_STRING(


in VSout
{
	vec2 TexCoord;
	vec3 Normal;
	vec3 FragPosWorld;
	vec3 RenderColor;
	vec4 FragPosDirLight[MAX_DIR_LIGHTS];
	vec4 FragPosSpotLight[MAX_SPOT_LIGHTS];
	mat3 TBN;
} fsin;

out vec4 Color;

struct Material
{
	vec3 Ka;
	vec3 Kd;
	vec3 Ks;
	vec3 Ke;
	float Ns;
	float d;
	float refl;
};

struct DirLight
{
	vec3 direction;

	vec3 ambient;
	vec3 diffuse;
	vec3 specular;
};

struct PointLight
{
	vec3 position;
	float zfar;

	vec3 ambient;
	vec3 diffuse;
	vec3 specular;

	vec3 K;
};

struct SpotLight
{
	vec3 position;
	vec3 direction;
	float innerAngle;
	float outerAngle;

	vec3 ambient;
	vec3 diffuse;
	vec3 specular;
};

uniform sampler2D map_albedo;
uniform sampler2D map_specular;
uniform sampler2D map_emmisive;
uniform sampler2D map_transparency;
uniform sampler2D map_normal;
uniform samplerCube map_pointLight_shadow[MAX_POINT_LIGHTS];
uniform sampler2D map_spotLight_shadow[MAX_SPOT_LIGHTS];
uniform sampler2D map_dirLight_shadow[MAX_DIR_LIGHTS];
uniform samplerCube map_skybox;
uniform int dirLightCount;
uniform int pointLightCount;
uniform int spotLightCount;
uniform int PCFdistance;
uniform vec3 fogColor;
uniform float fogDensity;
uniform float fogDistance;
uniform mat3 skyboxModelMatrix;
uniform Material material;
uniform vec3 viewPos;
uniform DirLight dirLight[MAX_DIR_LIGHTS];
uniform PointLight pointLight[MAX_POINT_LIGHTS];
uniform SpotLight spotLight[MAX_SPOT_LIGHTS];

float CalcShadowFactor2D(vec4 fragPosLight, sampler2D map_shadow)
{
	vec3 projCoords = fragPosLight.xyz / fragPosLight.w;
	float bias = 0.005f;
	float currentDepth = projCoords.z - bias;
	float shadowFactor = 0.0f;
	vec2 texelSize = 1.0f / textureSize(map_shadow, 0);
	for (int x = -PCFdistance; x <= PCFdistance; x++)
	{
		for (int y = -PCFdistance; y <= PCFdistance; y++)
		{
			float pcfDepth = texture(map_shadow, projCoords.xy + vec2(x, y) * texelSize).r;
			shadowFactor += currentDepth > pcfDepth ? 0.0f : 1.0f;
		}
	}
	int iterations = 2 * PCFdistance + 1;
	shadowFactor /= float(iterations * iterations);
	return shadowFactor;
}

vec3 sampleOffsetDirections[POINT_LIGHT_SAMPLES] = vec3[]
(
	vec3(1, 1, 1), vec3(1, -1, 1), vec3(-1, -1, 1), vec3(-1, 1, 1),
	vec3(1, 1, -1), vec3(1, -1, -1), vec3(-1, -1, -1), vec3(-1, 1, -1),
	vec3(1, 1, 0), vec3(1, -1, 0), vec3(-1, -1, 0), vec3(-1, 1, 0),
	vec3(1, 0, 1), vec3(-1, 0, 1), vec3(1, 0, -1), vec3(-1, 0, -1),
	vec3(0, 1, 1), vec3(0, -1, 1), vec3(0, -1, -1), vec3(0, 1, -1)
	);

float CalcShadowFactorCube(vec3 lightDistance, vec3 viewDist, float zfar, samplerCube map_shadow)
{
	float invZfar = 1.0f / zfar;
	float bias = 0.15f;
	float currentDepth = length(lightDistance);
	currentDepth = (currentDepth - bias) * invZfar;
	float shadowFactor = 0.0f;
	float diskRadius = (1.0f + length(viewDist) * invZfar) * 0.04f;

	for (int i = 0; i < POINT_LIGHT_SAMPLES; i++)
	{
		float closestDepth = texture(map_shadow, lightDistance + sampleOffsetDirections[i] * diskRadius).r;
		if (currentDepth < closestDepth)
			shadowFactor += 1.0f;
	}
	shadowFactor /= float(POINT_LIGHT_SAMPLES);
	return shadowFactor;
}

vec3 calcDirLight(vec3 ambient, vec3 diffuse, vec3 specular, DirLight light, vec3 normal, vec3 viewDir, vec3 reflection, vec4 fragLightSpace, sampler2D map_shadow)
{
	vec3 lightDir = normalize(light.direction);
	vec3 Hdir = normalize(lightDir + viewDir);
	float shadowFactor = CalcShadowFactor2D(fragLightSpace, map_shadow);

	float diffuseFactor = max(dot(lightDir, normal), 0.0f);
	float specularFactor = min(pow(max(dot(Hdir, normal), 0.0f), material.Ns), 0.5f);
	vec3 diffuseObject = diffuse * diffuseFactor;

	reflection = reflection * (diffuseObject + ambient);
	ambient = ambient * light.ambient;
	diffuse = light.diffuse * diffuseObject;
	specular = specular * light.specular * specularFactor;

	diffuse = (1.0f - material.refl) * diffuse;
	ambient = (1.0f - material.refl) * ambient;
	shadowFactor = max(shadowFactor, 0.5f);

	return vec3(ambient + shadowFactor * (diffuse + specular + reflection));
}

vec3 calcPointLight(vec3 ambient, vec3 diffuse, vec3 specular, PointLight light, vec3 normal, vec3 viewDir, samplerCube map_shadow)
{
	vec3 lightPath = fsin.FragPosWorld - light.position;
	vec3 lightDir = normalize(-lightPath);
	vec3 Hdir = normalize(lightDir + viewDir);
	float shadowFactor = CalcShadowFactorCube(lightPath, viewDir, light.zfar, map_shadow);

	float lightDistance = length(lightPath);
	float attenuation = 1.0f / (light.Kconstant + light.Klinear * lightDistance +
		light.Kquadratic * (lightDistance * lightDistance));

	float diffuseFactor = max(dot(lightDir, normal), 0.0f);
	float specularFactor = min(pow(max(dot(Hdir, normal), 0.0f), material.Ns), 0.5f);

	ambient = ambient * attenuation * light.ambient;
	diffuse = diffuse * attenuation * light.diffuse * diffuseFactor;
	specular = specular * attenuation * light.specular * specularFactor;

	return vec3(ambient + shadowFactor * (diffuse + specular));
}

vec3 calcSpotLight(vec3 ambient, vec3 diffuse, vec3 specular, SpotLight light, vec3 normal, vec3 viewDir, vec4 fragLightSpace, sampler2D map_shadow)
{
	vec3 lightDir = normalize(light.position - fsin.FragPosWorld);
	vec3 Hdir = normalize(lightDir + viewDir);
	float shadowFactor = CalcShadowFactor2D(fragLightSpace, map_shadow);

	float fragAngle = max(dot(lightDir, normalize(-light.direction)), 0.0f);
	float epsilon = light.innerAngle - light.outerAngle;
	float intensity = clamp((fragAngle - light.outerAngle) / epsilon, 0.0f, 1.0f);

	float diffuseFactor = max(dot(lightDir, normal), 0.0f);
	float specularFactor = min(pow(max(dot(Hdir, normal), 0.0f), material.Ns), 0.5f);

	ambient = ambient * intensity * light.ambient;
	diffuse = diffuse * intensity * light.diffuse * diffuseFactor;
	specular = specular * intensity * light.specular * specularFactor;

	return vec3(ambient + shadowFactor * (diffuse + specular));
}

vec3 calcReflection(vec3 viewDir, vec3 normal)
{
	vec3 I = -viewDir;
	vec3 reflection = reflect(I, normal);
	reflection = skyboxModelMatrix * reflection;
	vec3 color = material.refl * texture(map_skybox, reflection).rgb;
	return color;
}

vec3 calcNormal(vec2 texcoord, mat3 TBN)
{
	vec3 normal = texture(map_normal, texcoord).rgb;
	normal = normalize(normal * 2.0f - 1.0f);
	return TBN * normal;
}

vec3 applyFog(vec3 color, float distance, vec3 viewDir)
{
	float fogFactor = 1.0f - fogDistance * exp(-distance * fogDensity);
	return mix(color, fogColor, clamp(fogFactor, 0.0f, 1.0f));
}

void main()
{
	vec3 normal = calcNormal(fsin.TexCoord, fsin.TBN);
	vec3 viewDist = viewPos - fsin.FragPosWorld;
	vec3 viewDir = normalize(viewDist);

	vec3 albedoTex   = texture(map_albedo,   fsin.TexCoord).rgb;
	vec3 specularTex = texture(map_specular, fsin.TexCoord).rgb;
	vec3 emmisiveTex = texture(map_emmisive, fsin.TexCoord).rgb;

	vec3 reflection = calcReflection(viewDir, normal);
	vec3 ambient  = albedoTex   * material.Ka;
	vec3 diffuse  = albedoTex   * material.Kd;
	vec3 specular = specularTex * material.Ks;
	vec3 emmisive = emmisiveTex * material.Ke;

	vec3 color = vec3(0.0f);
	// directional lights
	for (int i = 0; i < dirLightCount; i++)
	{
		color += calcDirLight(ambient, diffuse, specular, dirLight[i], normal, viewDir, reflection, fsin.FragPosDirLight[i], map_dirLight_shadow[i]);
	}
	// point lights
	for (int i = 0; i < pointLightCount; i++)
	{
		color += calcPointLight(ambient, diffuse, specular, pointLight[i], normal, viewDist, map_pointLight_shadow[i]);
	}
	// spot lights
	for (int i = 0; i < spotLightCount; i++)
	{
		color += calcSpotLight(ambient, diffuse, specular, spotLight[i], normal, viewDir, fsin.FragPosSpotLight[i], map_spotLight_shadow[i]);
	}
	float transparencyTex = texture(map_transparency, fsin.TexCoord).r;
	float transparency = material.d * transparencyTex;

	color = applyFog(color, length(viewDist), viewDir);

	// emmisive light
	color += 5.0f * emmisive;
	color *= fsin.RenderColor;
	Color = vec4(color, transparency);
}

)