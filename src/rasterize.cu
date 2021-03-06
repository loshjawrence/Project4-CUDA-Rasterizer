/**
 * @file      rasterize.cu
 * @brief     CUDA-accelerated rasterization pipeline.
 * @authors   Skeleton code: Yining Karl Li, Kai Ninomiya, Shuai Shao (Shrek)
 * @date      2012-2016
 * @copyright University of Pennsylvania & STUDENT
 */

#include <cmath>
#include <cstdio>
#include <cuda.h>
#include <cuda_runtime.h>
#include <thrust/random.h>
#include <util/checkCUDAError.h>
#include <util/tiny_gltf_loader.h>
#include "rasterizeTools.h"
#include "rasterize.h"
#include <glm/gtc/quaternion.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <chrono>
#define SSAA 1;//4 or 16, subsample patter is grid so can only really do numbers with integer sqrt's, i.e. form a grid
#define MSAA 1;//same as above
#define TIMER 1

#if 1 < SSAA 
static const int AASCALING = SSAA;
#elif 1 < MSAA
static const int AASCALING = MSAA;
#else
static const int AASCALING = 1;
#endif

static const int sqrtAASCALING = glm::sqrt(AASCALING);

template<typename T>
void printElapsedTime(T time, std::string note = "") {
	std::cout << "   elapsed time: " << time << "ms    " << note << std::endl;
}

namespace {

	typedef unsigned short VertexIndex;
	typedef glm::vec3 VertexAttributePosition;
	typedef glm::vec3 VertexAttributeNormal;
	typedef glm::vec2 VertexAttributeTexcoord;
	typedef unsigned char TextureData;

	typedef unsigned char BufferByte;

	enum PrimitiveType{
		Point = 1,
		Line = 2,
		Triangle = 3
	};

	struct VertexOut {
		glm::vec4 pos;

		// TODO: add new attributes to your VertexOut
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		 glm::vec3 eyePos;	// eye space position used for shading
		 glm::vec3 eyeNor;	// eye space normal used for shading, cuz normal will go wrong after perspective transformation
		 glm::vec3 col;
		 glm::vec2 texcoord0;
		 TextureData* dev_diffuseTex = NULL;
		 int texWidth, texHeight;
		// ...
	};

	struct Primitive {
		PrimitiveType primitiveType = Triangle;	// C++ 11 init
		VertexOut v[3];
	};

	struct Fragment {
		glm::vec3 color;

		// TODO: add new attributes to your Fragment
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		 glm::vec3 eyePos;	// eye space position used for shading
		 glm::vec3 eyeNor;
		 VertexAttributeTexcoord texcoord0;
		 TextureData* dev_diffuseTex;
		 int texWidth, texHeight;
		// ...
	};

	struct PrimitiveDevBufPointers {
		int primitiveMode;	//from tinygltfloader macro
		PrimitiveType primitiveType;
		int numPrimitives;
		int numIndices;
		int numVertices;

		// Vertex In, const after loaded
		VertexIndex* dev_indices;
		VertexAttributePosition* dev_position;
		VertexAttributeNormal* dev_normal;
		VertexAttributeTexcoord* dev_texcoord0;

		// Materials, add more attributes when needed
		TextureData* dev_diffuseTex;
		int diffuseTexWidth;
		int diffuseTexHeight;
		// TextureData* dev_specularTex;
		// TextureData* dev_normalTex;
		// ...

		// Vertex Out, vertex used for rasterization, this is changing every frame
		VertexOut* dev_verticesOut;

		// TODO: add more attributes when needed
	};

}

static std::map<std::string, std::vector<PrimitiveDevBufPointers>> mesh2PrimitivesMap;


static int width = 0;
static int height = 0;

static int totalNumPrimitives = 0;
static Primitive *dev_primitives = NULL;
static Fragment *dev_fragmentBuffer = NULL;
static glm::vec3 *dev_framebuffer = NULL;
static int* dev_mutices = NULL;

static int * dev_depth = NULL;	// you might need this buffer when doing depth test

/**
 * Kernel that writes the image to the OpenGL PBO directly.
 */
__global__ 
void sendImageToPBO(uchar4 *pbo, int w, int h, glm::vec3 *image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
        glm::vec3 color;
        color.x = glm::clamp(image[index].x, 0.0f, 1.0f) * 255.0;
        color.y = glm::clamp(image[index].y, 0.0f, 1.0f) * 255.0;
        color.z = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

/** 
* Writes fragment colors to the framebuffer
*/
__global__
void render(const int wimage, const int himage, const int sqrtAASCALING, 
	const Fragment* const fragmentBuffer, glm::vec3* const framebuffer) 
{
    const int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    const int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x >= wimage && y >= himage) { return; }
	//framebuffer[index] = fragmentBuffer[index].color;
	// TODO: add your fragment shader code here

	//LOOP over AA samples
	const int wAA = wimage * sqrtAASCALING;
	const int hAA = himage * sqrtAASCALING;
	const int xAAstart = x*sqrtAASCALING;
	const int yAAstart = y*sqrtAASCALING;
	const int yAAend = glm::min(hAA, yAAstart + sqrtAASCALING);
	const int xAAend = glm::min(wAA, xAAstart + sqrtAASCALING);
	const int total = (xAAstart - xAAend) * (yAAstart-yAAend);

    const int index = x + (y * wimage);
	glm::vec3 col(0);
	glm::vec3 finalcolor(0);
	for (int yAA = yAAstart; yAA < yAAend; ++yAA) {
		for (int xAA = xAAstart; xAA < xAAend; ++xAA) {
			const int index = xAA + yAA*wAA;
			if (fragmentBuffer[index].dev_diffuseTex != NULL) {
			//if (false) {
				//compute color from texture
				const int width = fragmentBuffer[index].texWidth;
				const int height = fragmentBuffer[index].texHeight;
				const float texX_float = fragmentBuffer[index].texcoord0.x * width;
				const float texY_float = fragmentBuffer[index].texcoord0.y * height;
				const int texX_low = texX_float;
				const int texX_high = texX_low == width - 1 ? texX_low : texX_low + 1;
				const int texY_low = texY_float;
				const int texY_high = texY_low == width - 1 ? texY_low : texY_low + 1;
				const float uX = texX_float - texX_low;
				const float uY = texY_float - texY_low;
				const int rgbindex_Redlowleft = 3 * (texY_low* width + texX_low);
				const int rgbindex_Redlowright = 3 * (texY_low* width + texX_high);
				const int rgbindex_Redhighleft = 3 * (texY_high*width + texX_low);
				const int rgbindex_Redhighright = 3 * (texY_high*width + texX_high);
				const float toFloat = 1.f / 255.f;

				//bilinear interpolation
				const glm::vec3 col_lowleft(fragmentBuffer[index].dev_diffuseTex[rgbindex_Redlowleft + 0] ,
											fragmentBuffer[index].dev_diffuseTex[rgbindex_Redlowleft + 1] ,
											fragmentBuffer[index].dev_diffuseTex[rgbindex_Redlowleft + 2] );

				const glm::vec3 col_lowright(fragmentBuffer[index].dev_diffuseTex[rgbindex_Redlowright + 0] ,
											 fragmentBuffer[index].dev_diffuseTex[rgbindex_Redlowright + 1] ,
											 fragmentBuffer[index].dev_diffuseTex[rgbindex_Redlowright + 2] );

				const glm::vec3 col_highleft(fragmentBuffer[index].dev_diffuseTex[rgbindex_Redhighleft + 0] ,
											 fragmentBuffer[index].dev_diffuseTex[rgbindex_Redhighleft + 1] ,
											 fragmentBuffer[index].dev_diffuseTex[rgbindex_Redhighleft + 2] );

				const glm::vec3 col_highright(fragmentBuffer[index].dev_diffuseTex[rgbindex_Redhighright + 0],
											 fragmentBuffer[index].dev_diffuseTex[rgbindex_Redhighright + 1] ,
											 fragmentBuffer[index].dev_diffuseTex[rgbindex_Redhighright + 2] );

				const glm::vec3 lowXinterp = col_lowright*uX + col_lowleft*(1.f - uX);
				const glm::vec3 highXinterp = col_highright*uX + col_highleft*(1.f - uX);
				const glm::vec3 finalinterp = highXinterp*uY + lowXinterp*(1.f - uY);

				col = finalinterp * toFloat;
				//col = glm::vec3(fragmentBuffer[index].dev_diffuseTex[rgbindex_Redlowleft + 0] * toFloat,
				//				fragmentBuffer[index].dev_diffuseTex[rgbindex_Redlowleft + 1] * toFloat,
				//				fragmentBuffer[index].dev_diffuseTex[rgbindex_Redlowleft + 2] * toFloat);

			} else {
				col = fragmentBuffer[index].color;
			}

			const int mode = 1;

			//diffuse shading
			if (0 == mode) {
				const glm::vec3 lightDir = glm::normalize(glm::vec3(1, 1, 1));
				//framebuffer[index] = glm::dot(lightDir, fragmentBuffer[index].eyeNor) * col;
				finalcolor += glm::dot(lightDir, fragmentBuffer[index].eyeNor) * col;


				//blinn-phong shading model from wikipedia
			} else {
				const glm::vec3 lightPos(10.0, 10.0, 10.0);
				const glm::vec3 ambientColor(0.0, 0.0, 0.0);
				//const glm::vec3 diffuseColor(0.5, 0.0, 0.0);
				const glm::vec3 diffuseColor(col);
				const glm::vec3 specColor(1.0, 1.0, 1.0);
				const float shininess = 16.0;
				const float screenGamma = 2.2; // Assume the monitor is calibrated to the sRGB color space

				const glm::vec3 normal = fragmentBuffer[index].eyeNor;
				const glm::vec3 fragPos = fragmentBuffer[index].eyePos;
				const glm::vec3 lightDir = normalize(lightPos - fragPos);

				const float lambertian = glm::max(glm::dot(lightDir, normal), 0.f);
				float specular = 0.0;

				if (lambertian > 0.0) {
					glm::vec3 viewDir = glm::normalize(-fragPos);

					// this is blinn phong
					const glm::vec3 halfDir = glm::normalize(lightDir + viewDir);
					float specAngle = glm::max(glm::dot(halfDir, normal), 0.f);
					specular = glm::pow(specAngle, shininess);

					// this is phong (for comparison)
					if (mode == 2) {
						glm::vec3 reflectDir = glm::reflect(-lightDir, normal);
						specAngle = glm::max(glm::dot(reflectDir, viewDir), 0.f);//same as HalfDotNor
						// note that the exponent is different here
						specular = glm::pow(specAngle, shininess / 4.f);
					}
				}
				const glm::vec3 colorLinear = ambientColor + lambertian * diffuseColor + specular * specColor;
				// apply gamma correction (assume ambientColor, diffuseColor and specColor
				// have been linearized, i.e. have no gamma correction in them)
				const glm::vec3 colorGammaCorrected = glm::pow(colorLinear, glm::vec3(1.f / screenGamma));
				// use the gamma corrected color in the fragment
				//framebuffer[index] = colorGammaCorrected;
				finalcolor += colorGammaCorrected;
			}
		}
	}

	framebuffer[index] = finalcolor * (1.f/total);
}

/**
 * Called once at the beginning of the program to allocate memory.
 */
void rasterizeInit(int w, int h) {
    width = w;
    height = h;

    cudaFree(dev_framebuffer);
    cudaMalloc(&dev_framebuffer,   width * height * sizeof(glm::vec3));
    cudaMemset(dev_framebuffer, 0, width * height * sizeof(glm::vec3));

	cudaFree(dev_fragmentBuffer);
	cudaMalloc(&dev_fragmentBuffer,   AASCALING * width * height * sizeof(Fragment));
	cudaMemset(dev_fragmentBuffer, 0, AASCALING * width * height * sizeof(Fragment));

	cudaFree(dev_depth);
	cudaMalloc(&dev_depth, AASCALING * width * height * sizeof(int));

    cudaFree(dev_mutices);
	cudaMalloc(&dev_mutices,   AASCALING * width * height * sizeof(int));
	cudaMemset(dev_mutices, 0, AASCALING * width * height * sizeof(int));
    
	checkCUDAError("rasterizeInit");
}

__global__
void initDepth(int w, int h, int * depth)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < w && y < h)
	{
		int index = x + (y * w);
		depth[index] = INT_MAX;
	}
}


/**
* kern function with support for stride to sometimes replace cudaMemcpy
* One thread is responsible for copying one component
*/
__global__ 
void _deviceBufferCopy(int N, BufferByte* dev_dst, const BufferByte* dev_src, int n, int byteStride, int byteOffset, int componentTypeByteSize) {
	
	// Attribute (vec3 position)
	// component (3 * float)
	// byte (4 * byte)

	// id of component
	int i = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (i < N) {
		int count = i / n;
		int offset = i - count * n;	// which component of the attribute

		for (int j = 0; j < componentTypeByteSize; j++) {
			
			dev_dst[count * componentTypeByteSize * n 
				+ offset * componentTypeByteSize 
				+ j]

				= 

			dev_src[byteOffset 
				+ count * (byteStride == 0 ? componentTypeByteSize * n : byteStride) 
				+ offset * componentTypeByteSize 
				+ j];
		}
	}
	

}

__global__
void _nodeMatrixTransform(
	int numVertices,
	VertexAttributePosition* position,
	VertexAttributeNormal* normal,
	glm::mat4 MV, glm::mat3 MV_normal) {

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {
		position[vid] = glm::vec3(MV * glm::vec4(position[vid], 1.0f));
		normal[vid] = glm::normalize(MV_normal * normal[vid]);
	}
}

glm::mat4 getMatrixFromNodeMatrixVector(const tinygltf::Node & n) {
	
	glm::mat4 curMatrix(1.0);

	const std::vector<double> &m = n.matrix;
	if (m.size() > 0) {
		// matrix, copy it

		for (int i = 0; i < 4; i++) {
			for (int j = 0; j < 4; j++) {
				curMatrix[i][j] = (float)m.at(4 * i + j);
			}
		}
	} else {
		// no matrix, use rotation, scale, translation

		if (n.translation.size() > 0) {
			curMatrix[3][0] = n.translation[0];
			curMatrix[3][1] = n.translation[1];
			curMatrix[3][2] = n.translation[2];
		}

		if (n.rotation.size() > 0) {
			glm::mat4 R;
			glm::quat q;
			q[0] = n.rotation[0];
			q[1] = n.rotation[1];
			q[2] = n.rotation[2];

			R = glm::mat4_cast(q);
			curMatrix = curMatrix * R;
		}

		if (n.scale.size() > 0) {
			curMatrix = curMatrix * glm::scale(glm::vec3(n.scale[0], n.scale[1], n.scale[2]));
		}
	}

	return curMatrix;
}

void traverseNode (
	std::map<std::string, glm::mat4> & n2m,
	const tinygltf::Scene & scene,
	const std::string & nodeString,
	const glm::mat4 & parentMatrix
	) 
{
	const tinygltf::Node & n = scene.nodes.at(nodeString);
	glm::mat4 M = parentMatrix * getMatrixFromNodeMatrixVector(n);
	n2m.insert(std::pair<std::string, glm::mat4>(nodeString, M));

	auto it = n.children.begin();
	auto itEnd = n.children.end();

	for (; it != itEnd; ++it) {
		traverseNode(n2m, scene, *it, M);
	}
}

void rasterizeSetBuffers(const tinygltf::Scene & scene) {

	totalNumPrimitives = 0;

	std::map<std::string, BufferByte*> bufferViewDevPointers;

	// 1. copy all `bufferViews` to device memory
	{
		std::map<std::string, tinygltf::BufferView>::const_iterator it(
			scene.bufferViews.begin());
		std::map<std::string, tinygltf::BufferView>::const_iterator itEnd(
			scene.bufferViews.end());

		for (; it != itEnd; it++) {
			const std::string key = it->first;
			const tinygltf::BufferView &bufferView = it->second;
			if (bufferView.target == 0) {
				continue; // Unsupported bufferView.
			}

			const tinygltf::Buffer &buffer = scene.buffers.at(bufferView.buffer);

			BufferByte* dev_bufferView;
			cudaMalloc(&dev_bufferView, bufferView.byteLength);
			cudaMemcpy(dev_bufferView, &buffer.data.front() + bufferView.byteOffset, bufferView.byteLength, cudaMemcpyHostToDevice);

			checkCUDAError("Set BufferView Device Mem");

			bufferViewDevPointers.insert(std::make_pair(key, dev_bufferView));

		}
	}



	// 2. for each mesh: 
	//		for each primitive: 
	//			build device buffer of indices, materail, and each attributes
	//			and store these pointers in a map
	{

		std::map<std::string, glm::mat4> nodeString2Matrix;
		auto rootNodeNamesList = scene.scenes.at(scene.defaultScene);

		{
			auto it = rootNodeNamesList.begin();
			auto itEnd = rootNodeNamesList.end();
			for (; it != itEnd; ++it) {
				traverseNode(nodeString2Matrix, scene, *it, glm::mat4(1.0f));
			}
		}


		// parse through node to access mesh

		auto itNode = nodeString2Matrix.begin();
		auto itEndNode = nodeString2Matrix.end();
		for (; itNode != itEndNode; ++itNode) {

			const tinygltf::Node & N = scene.nodes.at(itNode->first);
			const glm::mat4 & matrix = itNode->second;
			const glm::mat3 & matrixNormal = glm::transpose(glm::inverse(glm::mat3(matrix)));

			auto itMeshName = N.meshes.begin();
			auto itEndMeshName = N.meshes.end();

			for (; itMeshName != itEndMeshName; ++itMeshName) {

				const tinygltf::Mesh & mesh = scene.meshes.at(*itMeshName);

				auto res = mesh2PrimitivesMap.insert(std::pair<std::string, std::vector<PrimitiveDevBufPointers>>(mesh.name, std::vector<PrimitiveDevBufPointers>()));
				std::vector<PrimitiveDevBufPointers> & primitiveVector = (res.first)->second;

				// for each primitive
				for (size_t i = 0; i < mesh.primitives.size(); i++) {
					const tinygltf::Primitive &primitive = mesh.primitives[i];

					if (primitive.indices.empty())
						return;

					// TODO: add new attributes for your PrimitiveDevBufPointers when you add new attributes
					VertexIndex* dev_indices = NULL;
					VertexAttributePosition* dev_position = NULL;
					VertexAttributeNormal* dev_normal = NULL;
					VertexAttributeTexcoord* dev_texcoord0 = NULL;

					// ----------Indices-------------

					const tinygltf::Accessor &indexAccessor = scene.accessors.at(primitive.indices);
					const tinygltf::BufferView &bufferView = scene.bufferViews.at(indexAccessor.bufferView);
					BufferByte* dev_bufferView = bufferViewDevPointers.at(indexAccessor.bufferView);

					// assume type is SCALAR for indices
					int n = 1;
					int numIndices = indexAccessor.count;
					int componentTypeByteSize = sizeof(VertexIndex);
					int byteLength = numIndices * n * componentTypeByteSize;

					dim3 numThreadsPerBlock(128);
					dim3 numBlocks((numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					cudaMalloc(&dev_indices, byteLength);
					_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
						numIndices,
						(BufferByte*)dev_indices,
						dev_bufferView,
						n,
						indexAccessor.byteStride,
						indexAccessor.byteOffset,
						componentTypeByteSize);


					checkCUDAError("Set Index Buffer");


					// ---------Primitive Info-------

					// Warning: LINE_STRIP is not supported in tinygltfloader
					int numPrimitives;
					PrimitiveType primitiveType;
					switch (primitive.mode) {
					case TINYGLTF_MODE_TRIANGLES:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices / 3;
						break;
					case TINYGLTF_MODE_TRIANGLE_STRIP:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_TRIANGLE_FAN:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_LINE:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices / 2;
						break;
					case TINYGLTF_MODE_LINE_LOOP:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices + 1;
						break;
					case TINYGLTF_MODE_POINTS:
						primitiveType = PrimitiveType::Point;
						numPrimitives = numIndices;
						break;
					default:
						// output error
						break;
					};


					// ----------Attributes-------------

					auto it(primitive.attributes.begin());
					auto itEnd(primitive.attributes.end());

					int numVertices = 0;
					// for each attribute
					for (; it != itEnd; it++) {
						const tinygltf::Accessor &accessor = scene.accessors.at(it->second);
						const tinygltf::BufferView &bufferView = scene.bufferViews.at(accessor.bufferView);

						int n = 1;
						if (accessor.type == TINYGLTF_TYPE_SCALAR) {
							n = 1;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC2) {
							n = 2;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC3) {
							n = 3;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC4) {
							n = 4;
						}

						BufferByte * dev_bufferView = bufferViewDevPointers.at(accessor.bufferView);
						BufferByte ** dev_attribute = NULL;

						numVertices = accessor.count;
						int componentTypeByteSize;

						// Note: since the type of our attribute array (dev_position) is static (float32)
						// We assume the glTF model attribute type are 5126(FLOAT) here

						if (it->first.compare("POSITION") == 0) {
							componentTypeByteSize = sizeof(VertexAttributePosition) / n;
							dev_attribute = (BufferByte**)&dev_position;
						}
						else if (it->first.compare("NORMAL") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeNormal) / n;
							dev_attribute = (BufferByte**)&dev_normal;
						}
						else if (it->first.compare("TEXCOORD_0") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeTexcoord) / n;
							dev_attribute = (BufferByte**)&dev_texcoord0;
						}

						std::cout << accessor.bufferView << "  -  " << it->second << "  -  " << it->first << '\n';

						dim3 numThreadsPerBlock(128);
						dim3 numBlocks((n * numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
						int byteLength = numVertices * n * componentTypeByteSize;
						cudaMalloc(dev_attribute, byteLength);

						_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
							n * numVertices,
							*dev_attribute,
							dev_bufferView,
							n,
							accessor.byteStride,
							accessor.byteOffset,
							componentTypeByteSize);

						std::string msg = "Set Attribute Buffer: " + it->first;
						checkCUDAError(msg.c_str());
					}

					// malloc for VertexOut
					VertexOut* dev_vertexOut;
					cudaMalloc(&dev_vertexOut, numVertices * sizeof(VertexOut));
					checkCUDAError("Malloc VertexOut Buffer");

					// ----------Materials-------------

					// You can only worry about this part once you started to 
					// implement textures for your rasterizer
					TextureData* dev_diffuseTex = NULL;
					int diffuseTexWidth = 0;
					int diffuseTexHeight = 0;
					if (!primitive.material.empty()) {
						const tinygltf::Material &mat = scene.materials.at(primitive.material);
						printf("material.name = %s\n", mat.name.c_str());

						if (mat.values.find("diffuse") != mat.values.end()) {
							std::string diffuseTexName = mat.values.at("diffuse").string_value;
							if (scene.textures.find(diffuseTexName) != scene.textures.end()) {
								const tinygltf::Texture &tex = scene.textures.at(diffuseTexName);
								if (scene.images.find(tex.source) != scene.images.end()) {
									const tinygltf::Image &image = scene.images.at(tex.source);

									size_t s = image.image.size() * sizeof(TextureData);
									cudaMalloc(&dev_diffuseTex, s);
									cudaMemcpy(dev_diffuseTex, &image.image.at(0), s, cudaMemcpyHostToDevice);
									
									diffuseTexWidth = image.width;
									diffuseTexHeight = image.height;

									checkCUDAError("Set Texture Image data");
								}
							}
						}

						// TODO: write your code for other materails
						// You may have to take a look at tinygltfloader
						// You can also use the above code loading diffuse material as a start point 
					}


					// ---------Node hierarchy transform--------
					cudaDeviceSynchronize();
					
					dim3 numBlocksNodeTransform((numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					_nodeMatrixTransform << <numBlocksNodeTransform, numThreadsPerBlock >> > (
						numVertices,
						dev_position,
						dev_normal,
						matrix,
						matrixNormal);

					checkCUDAError("Node hierarchy transformation");

					// at the end of the for loop of primitive
					// push dev pointers to map
					primitiveVector.push_back(PrimitiveDevBufPointers{
						primitive.mode,
						primitiveType,
						numPrimitives,
						numIndices,
						numVertices,

						dev_indices,
						dev_position,
						dev_normal,
						dev_texcoord0,

						dev_diffuseTex,
						diffuseTexWidth,
						diffuseTexHeight,

						dev_vertexOut	//VertexOut
					});

					totalNumPrimitives += numPrimitives;

				} // for each primitive

			} // for each mesh

		} // for each node

	}
	

	// 3. Malloc for dev_primitives
	{
		cudaMalloc(&dev_primitives, totalNumPrimitives * sizeof(Primitive));
	}
	

	// Finally, cudaFree raw dev_bufferViews
	{

		std::map<std::string, BufferByte*>::const_iterator it(bufferViewDevPointers.begin());
		std::map<std::string, BufferByte*>::const_iterator itEnd(bufferViewDevPointers.end());
			
			//bufferViewDevPointers

		for (; it != itEnd; it++) {
			cudaFree(it->second);
		}

		checkCUDAError("Free BufferView Device Mem");
	}


}



__global__ 
void _vertexTransformAndAssembly(
	const int numVertices, 
	PrimitiveDevBufPointers primitive, 
	const glm::mat4 MVP, const glm::mat4 MV, const glm::mat3 MV_normal, 
	const int width, const int height) {

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid >= numVertices) { return; }

	// TODO: Apply vertex transformation here
	// Multiply the MVP matrix for each vertex position, this will transform everything into clipping space
	// Then divide the pos by its w element to transform into NDC space
	// Finally transform x and y to viewport space
	glm::vec4 viewportPos = MVP * glm::vec4(primitive.dev_position[vid], 1.f);
	viewportPos *= (1.f / viewportPos.w);
	//viewportPos.x = 0.5f * width  * (1.f + viewportPos.x);
	//viewportPos.y = 0.5f * height * (1.f - viewportPos.y);

	//int AASCALE = 1;
	//if (SSAA > 1) {
	//	AASCALE = SSAA;
	//} else if (MSAA > 1) {
	//	AASCALE = MSAA;
	//}

	viewportPos.x = 0.5f * width  * (1.f - viewportPos.x);//i guess upper right is 0,0 for this code
	viewportPos.y = 0.5f * height * (1.f - viewportPos.y);
	//ndc lowleft is -1,-1 and upright is 1,1. 
	//ndc x coords line up with how pixel coords are laid out( increase from left to right)
	//but ndc y coords are reversed, they increase from bottom to top but pixels coords increase from top to bottom, 
	//thats why we need to essential flip the ndc y coords by multiplying by -1
	//this puts ndc y vals of 1 at pixel y vals of 0(top of screen) and ndc y vals of -1 at pixel vals of height(bottom of screen)

	// TODO: Apply vertex assembly here
	// Assemble all attribute arraies into the primitive array
	if (0 != primitive.diffuseTexHeight && 0 != primitive.diffuseTexWidth && primitive.dev_diffuseTex != NULL) {
		primitive.dev_verticesOut[vid].texcoord0 = primitive.dev_texcoord0[vid];
		primitive.dev_verticesOut[vid].dev_diffuseTex = primitive.dev_diffuseTex;
		primitive.dev_verticesOut[vid].texWidth = primitive.diffuseTexWidth;
		primitive.dev_verticesOut[vid].texHeight = primitive.diffuseTexHeight;
	}
	primitive.dev_verticesOut[vid].eyeNor = glm::normalize(MV_normal * primitive.dev_normal[vid]);//cam space
	primitive.dev_verticesOut[vid].eyePos = glm::vec3(MV * glm::vec4(primitive.dev_position[vid], 1.f));//cam space
	primitive.dev_verticesOut[vid].pos = viewportPos;//pixel space 
	primitive.dev_verticesOut[vid].col = glm::vec3(1, 0, 0);
}



static int curPrimitiveBeginId = 0;

__global__ 
void _primitiveAssembly(const int numIndices, 
	const int curPrimitiveBeginId, Primitive* const dev_primitives, 
	const PrimitiveDevBufPointers primitive) 
{
	// index id
	int iid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (iid < numIndices) {
		// TODO: uncomment the following code for a start
		// This is primitive assembly for triangles
		if (primitive.primitiveMode == TINYGLTF_MODE_TRIANGLES) {
			const int pid = iid / (int)primitive.primitiveType;// id for cur primitives vector
			const int componentID = pid*(int)primitive.primitiveType - iid;//modulo is expensive
			dev_primitives[pid + curPrimitiveBeginId].v[iid % (int)primitive.primitiveType]
				= primitive.dev_verticesOut[primitive.dev_indices[iid]];
		}
		// TODO: other primitive types (point, line)
	}
	
}

__global__
void _baryRasterize(const Primitive* const primitives,
	const int numPrimitives, Fragment* const fragmentbuffer, int* const depth, int* const mutices, const int width, const int height)
{
	const int primID = blockIdx.x*blockDim.x + threadIdx.x;
	if (primID >= numPrimitives) { return; }

	const glm::vec3 screentri[3] = { glm::vec3(primitives[primID].v[0].pos),
									 glm::vec3(primitives[primID].v[1].pos),
									 glm::vec3(primitives[primID].v[2].pos) };

	const glm::vec3 primNor = glm::cross(screentri[1] - screentri[0], screentri[2] - screentri[0]);
	if (primNor.z < 0) { return; }

	const glm::vec3 eyetri[3] =    { glm::vec3(primitives[primID].v[0].eyePos),
									 glm::vec3(primitives[primID].v[1].eyePos),
									 glm::vec3(primitives[primID].v[2].eyePos) };

	const AABB bounds = getAABBForTriangle(screentri, width, height);
	for (int x = bounds.min.x; x < bounds.max.x; ++x) {
		for (int y = bounds.min.y; y < bounds.max.y; ++y) {
			const glm::vec3 barycoord = calculateBarycentricCoordinate(screentri, glm::vec2(x, y));
			if (!isBarycentricCoordInBounds(barycoord)) { continue; }
			//precompute all this before we hit the bottle neck of the atomicCAS
			//once we have the mutex we need to release it as soon as possible so other fragments can test their depths
			const float perspcorrectz = getPerspectiveCorrectZAtBaryCoord(barycoord, eyetri);
			if (perspcorrectz >= 0) { continue; }
			const float perspBary0 = (perspcorrectz / eyetri[0].z) * barycoord[0];
			const float perspBary1 = (perspcorrectz / eyetri[1].z) * barycoord[1];
			const float perspBary2 = (perspcorrectz / eyetri[2].z) * barycoord[2];

			const glm::vec3 fragEyeNor =    perspBary0 * primitives[primID].v[0].eyeNor +
										    perspBary1 * primitives[primID].v[1].eyeNor +
										    perspBary2 * primitives[primID].v[2].eyeNor;

			const glm::vec3 fragEyePos =    perspBary0 * primitives[primID].v[0].eyePos +
										    perspBary1 * primitives[primID].v[1].eyePos +
										    perspBary2 * primitives[primID].v[2].eyePos;

			const glm::vec2 fragTexCoord0 = perspBary0 * primitives[primID].v[0].texcoord0 +
											perspBary1 * primitives[primID].v[1].texcoord0 +
											perspBary2 * primitives[primID].v[2].texcoord0;

			const glm::vec3 fragCol =	    perspBary0 * primitives[primID].v[0].col +
										    perspBary1 * primitives[primID].v[1].col +
										    perspBary2 * primitives[primID].v[2].col;

			//https://stackoverflow.com/questions/21341495/cuda-mutex-and-atomiccas
			const int pixelidx = x + y*width;
			int* mutex = &mutices[pixelidx];
			bool isSet = false;
			const float depthBufScale = -100000.f;//helps with sorting, depth buffer holds int values, val between near and far plane will be less than 1(if NDC z)
			//slide the decimal point over so we can compare ints with ints and differentiate between fractional parts of the z values

			do {
				if (isSet = atomicCAS(mutex, 0, 1) == 0) {
					if (depth[pixelidx] > depthBufScale*perspcorrectz) {
						depth[pixelidx] = depthBufScale*perspcorrectz;
						fragmentbuffer[pixelidx].color = fragCol;
						fragmentbuffer[pixelidx].eyePos = fragEyePos;
						fragmentbuffer[pixelidx].eyeNor = fragEyeNor;
						fragmentbuffer[pixelidx].texcoord0 = fragTexCoord0;
						fragmentbuffer[pixelidx].dev_diffuseTex = primitives[primID].v[0].dev_diffuseTex;
						fragmentbuffer[pixelidx].texWidth = primitives[primID].v[0].texWidth;
						fragmentbuffer[pixelidx].texHeight = primitives[primID].v[0].texHeight;
					}
				}
				if (isSet) { *mutex = 0; }
			} while (!isSet);
		}//x
	}//y
}


/**
 * Perform rasterization.
 */
void rasterize(uchar4 *pbo, const glm::mat4 & MVP, const glm::mat4 & MV, const glm::mat3 MV_normal) {
    int sideLength2d = 8;
    dim3 blockSize2d(sideLength2d, sideLength2d);
    dim3 blockCount2d((width  - 1) / blockSize2d.x + 1,
		(height - 1) / blockSize2d.y + 1);

	// Execute your rasterization pipeline here
	// (See README for rasterization pipeline outline.)

	// Vertex Process & primitive assembly
	{
		curPrimitiveBeginId = 0;
		dim3 numThreadsPerBlock(128);

		auto it = mesh2PrimitivesMap.begin();
		auto itEnd = mesh2PrimitivesMap.end();

#if 1 == TIMER
	using time_point_t = std::chrono::high_resolution_clock::time_point;
	time_point_t time_start_cpu = std::chrono::high_resolution_clock::now();
#endif
		for (; it != itEnd; ++it) {
			auto p = (it->second).begin();	// each primitive
			auto pEnd = (it->second).end();
			for (; p != pEnd; ++p) {
				dim3 numBlocksForVertices((p->numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
				dim3 numBlocksForIndices((p->numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);

				_vertexTransformAndAssembly << < numBlocksForVertices, numThreadsPerBlock >> >(p->numVertices, *p, MVP, MV, MV_normal, sqrtAASCALING*width, sqrtAASCALING*height);
				checkCUDAError("Vertex Processing");
				cudaDeviceSynchronize();
				_primitiveAssembly << < numBlocksForIndices, numThreadsPerBlock >> >
					(p->numIndices, 
					curPrimitiveBeginId, 
					dev_primitives, 
					*p);
				checkCUDAError("Primitive Assembly");

				curPrimitiveBeginId += p->numPrimitives;
			}
		}
#if 1 == TIMER
	cudaDeviceSynchronize();
	time_point_t time_end_cpu = std::chrono::high_resolution_clock::now();
	std::chrono::duration<double, std::milli> duro = time_end_cpu - time_start_cpu;
	float prev_elapsed_time_cpu_milliseconds = static_cast<decltype(prev_elapsed_time_cpu_milliseconds)>(duro.count());
	printElapsedTime(prev_elapsed_time_cpu_milliseconds, "vertex assembly, vertex transform, prim assembly(std::chrono Measured)");
#endif

		checkCUDAError("Vertex Processing and Primitive Assembly");
	}
	
	cudaMemset(dev_fragmentBuffer, 0, AASCALING * width * height * sizeof(Fragment));
    dim3 blockCount2dAA((sqrtAASCALING*width  - 1) / blockSize2d.x + 1,
		(sqrtAASCALING*height - 1) / blockSize2d.y + 1);
	initDepth << <blockCount2dAA, blockSize2d >> >(sqrtAASCALING*width, sqrtAASCALING*height, dev_depth);
	checkCUDAError("initDepth");
	
#if 1 == TIMER
	using time_point_t = std::chrono::high_resolution_clock::time_point;
	time_point_t time_start_cpu = std::chrono::high_resolution_clock::now();
#endif
	// TODO: rasterize
	const int numThreadsPerBlock = 128;
	const int numBlocksForPrimitives = (totalNumPrimitives + numThreadsPerBlock - 1) / numThreadsPerBlock;
	_baryRasterize<<<numBlocksForPrimitives, numThreadsPerBlock>>>(dev_primitives, totalNumPrimitives, 
		dev_fragmentBuffer, dev_depth, dev_mutices, sqrtAASCALING*width, sqrtAASCALING*height);
	checkCUDAError("_baryRasterize");
#if 1 == TIMER
	cudaDeviceSynchronize();
	time_point_t time_end_cpu = std::chrono::high_resolution_clock::now();
	std::chrono::duration<double, std::milli> duro = time_end_cpu - time_start_cpu;
	float prev_elapsed_time_cpu_milliseconds = static_cast<decltype(prev_elapsed_time_cpu_milliseconds)>(duro.count());
	printElapsedTime(prev_elapsed_time_cpu_milliseconds, "Rasterize(std::chrono Measured)");
#endif

#if 1 == TIMER
	time_start_cpu = std::chrono::high_resolution_clock::now();
#endif
    // Copy depthbuffer colors into framebuffer
	render<<<blockCount2d, blockSize2d>>>(width, height, sqrtAASCALING, dev_fragmentBuffer, dev_framebuffer);
	checkCUDAError("fragment shader");
#if 1 == TIMER
	cudaDeviceSynchronize();
	time_end_cpu = std::chrono::high_resolution_clock::now();
	duro = time_end_cpu - time_start_cpu;
	prev_elapsed_time_cpu_milliseconds = static_cast<decltype(prev_elapsed_time_cpu_milliseconds)>(duro.count());
	printElapsedTime(prev_elapsed_time_cpu_milliseconds, "Render(std::chrono Measured)");
#endif



    // Copy framebuffer into OpenGL buffer for OpenGL previewing
    sendImageToPBO<<<blockCount2d, blockSize2d>>>(pbo, width, height, dev_framebuffer);
    checkCUDAError("copy render result to pbo");
}

/**
 * Called once at the end of the program to free CUDA memory.
 */
void rasterizeFree() {

    // deconstruct primitives attribute/indices device buffer

	auto it(mesh2PrimitivesMap.begin());
	auto itEnd(mesh2PrimitivesMap.end());
	for (; it != itEnd; ++it) {
		for (auto p = it->second.begin(); p != it->second.end(); ++p) {
			cudaFree(p->dev_indices);
			cudaFree(p->dev_position);
			cudaFree(p->dev_normal);
			cudaFree(p->dev_texcoord0);
			cudaFree(p->dev_diffuseTex);

			cudaFree(p->dev_verticesOut);

			
			//TODO: release other attributes and materials
		}
	}

	////////////

    cudaFree(dev_primitives);
    dev_primitives = NULL;

	cudaFree(dev_fragmentBuffer);
	dev_fragmentBuffer = NULL;

    cudaFree(dev_framebuffer);
    dev_framebuffer = NULL;

	cudaFree(dev_depth);
	dev_depth = NULL;

	cudaFree(dev_mutices);
	dev_mutices = NULL;

    checkCUDAError("rasterize Free");
}
