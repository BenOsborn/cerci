#include "matrixfunctions.cuh"

// Defining the constants section for the thread blocks is a bit of a pain and feels messy

template <typename Lambda>
__global__
void applyD(int size, float* inVector, Lambda function) {
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index < size) inVector[index] = function(inVector[index]);
}

// Baically we want some sort of macro which is going to take in the matrix and copy the stuff and then we are going to extract the stuff from it

// What if instead of returning a matrix we create a seperate function which copies the memory address to some sort of location and then we can access this memory address andput the value into whatever we want
template <typename Lambda>
std::unique_ptr<Matrix> apply(std::unique_ptr<Matrix>& in_matrix, Lambda function) {
	std::unique_ptr<float[]> matrix = in_matrix->returnMatrix();
	int size = in_matrix->returnSize();
	std::unique_ptr<int[]> shape = in_matrix->returnShape();

	int bytes = size * sizeof(float);

	float* dCopy;
	cudaMalloc(&dCopy, bytes);
	cudaMemcpy(dCopy, matrix.get(), bytes, cudaMemcpyHostToDevice);

	GPUParams gpu;
	int dimGridX = (size + gpu.THREAD_SIZE - 1) / gpu.THREAD_SIZE;
	applyD <<< dimGridX, gpu.THREAD_SIZE >>> (size, dCopy, function);

	std::unique_ptr<float[]> new_matrix = std::make_unique<float[]>(size);
	cudaMemcpy(new_matrix.get(), dCopy, bytes, cudaMemcpyDeviceToHost);

	std::unique_ptr<Matrix> ret_matrix = std::make_unique<Matrix>(new_matrix, shape);

	cudaFree(dCopy);

	return ret_matrix;
}

__global__
void addD(int size, float* vector1, float* vector2, float* retVector) {
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index < size) retVector[index] = vector1[index] + vector2[index];
}

std::unique_ptr<Matrix> add(std::unique_ptr<Matrix>& matrix1, std::unique_ptr<Matrix>& matrix2) {
	std::unique_ptr<int[]> mat1shape = matrix1->returnShape();
	std::unique_ptr<int[]> mat2shape = matrix2->returnShape();
	if ((mat1shape[0] != mat2shape[0]) || (mat1shape[1] != mat2shape[1])) throw std::invalid_argument("Matrices are not of the same shape!");

	int size = matrix1->returnSize();
	int bytes = size * sizeof(float);

	std::unique_ptr<float[]> mat1 = matrix1->returnMatrix();
	std::unique_ptr<float[]> mat2 = matrix2->returnMatrix();

	float* mat1d;
	float* mat2d;
	float* mat3d;
	cudaMalloc(&mat1d, bytes);
	cudaMalloc(&mat2d, bytes);
	cudaMalloc(&mat3d, bytes);
	cudaMemcpy(mat1d, mat1.get(), bytes, cudaMemcpyHostToDevice);
	cudaMemcpy(mat2d, mat2.get(), bytes, cudaMemcpyHostToDevice);

	GPUParams gpu;
	int dimGridX = (size + gpu.THREAD_SIZE - 1) / gpu.THREAD_SIZE;
	addD <<< dimGridX, gpu.THREAD_SIZE >>> (size, mat1d, mat2d, mat3d);

	std::unique_ptr<float[]> mat3 = std::make_unique<float[]>(bytes);
	cudaMemcpy(mat3.get(), mat3d, bytes, cudaMemcpyDeviceToHost);

	std::unique_ptr<int[]> shape = matrix1->returnShape();
	std::unique_ptr<Matrix> ret_matrix = std::make_unique<Matrix>(mat3, shape);

	cudaFree(mat1d);
	cudaFree(mat2d);
	cudaFree(mat3d);

	return ret_matrix;
}

__global__
void multiplyD(int rows, int same, int cols, float* vector1, float* vector2, float* retVector) {
	int row = blockIdx.y * blockDim.y + threadIdx.y;
	int col = blockIdx.x * blockDim.x + threadIdx.x;

	if ((row < rows) && (col < cols)) {
		float sum = 0;
		for (int i = 0; i < same; i++) {
			sum += vector1[row * same + i] * vector2[i * cols + col];
		}
		retVector[row * cols + col] = sum;
	}
}

std::unique_ptr<Matrix> multiply(std::unique_ptr<Matrix>& matrix1, std::unique_ptr<Matrix>& matrix2) {
	std::unique_ptr<int[]> mat1shape = matrix1->returnShape();
	std::unique_ptr<int[]> mat2shape = matrix2->returnShape();
	if (mat1shape[1] != mat2shape[0]) throw std::invalid_argument("Matrix1's cols must equal Matrix2's rows!");

	std::unique_ptr<int[]> new_shape = std::make_unique<int[]>(2);
	new_shape[0] = mat1shape[0];
	new_shape[1] = mat2shape[1];
	int same = mat1shape[1];

	int mat1bytes = matrix1->returnSize() * sizeof(float);
	int mat2bytes = matrix2->returnSize() * sizeof(float);
	int mat3bytes = new_shape[0] * new_shape[1] * sizeof(float);

	float* mat1d;
	float* mat2d;
	float* mat3d;
	cudaMalloc(&mat1d, mat1bytes);
	cudaMalloc(&mat2d, mat2bytes);
	cudaMalloc(&mat3d, mat3bytes);

	std::unique_ptr<float[]> mat1 = matrix1->returnMatrix();
	std::unique_ptr<float[]> mat2 = matrix2->returnMatrix();
	cudaMemcpy(mat1d, mat1.get(), mat1bytes, cudaMemcpyHostToDevice);
	cudaMemcpy(mat2d, mat2.get(), mat2bytes, cudaMemcpyHostToDevice);

	GPUParams gpu;
	int grid_rows = (new_shape[0] + gpu.BLOCK_SIZE - 1) / gpu.BLOCK_SIZE;
	int grid_cols = (new_shape[1] + gpu.BLOCK_SIZE - 1) / gpu.BLOCK_SIZE;
	dim3 dimGrid(grid_cols, grid_rows);
	dim3 dimBlock(gpu.BLOCK_SIZE, gpu.BLOCK_SIZE);

	multiplyD <<< dimGrid, dimBlock >>> (new_shape[0], same, new_shape[1], mat1d, mat2d, mat3d);

	std::unique_ptr<float[]> mat3 = std::make_unique<float[]>(new_shape[0] * new_shape[1]);
	cudaMemcpy(mat3.get(), mat3d, mat3bytes, cudaMemcpyDeviceToHost);

	std::unique_ptr<Matrix> ret_matrix = std::make_unique<Matrix>(mat3, new_shape);

	cudaFree(mat1d);
	cudaFree(mat2d);
	cudaFree(mat3d);

	return ret_matrix;
}

std::unique_ptr<Matrix> genRand(int rows, int cols) {
	std::unique_ptr<int[]> shape = std::make_unique<int[]>(2);
	shape[0] = rows;
	shape[1] = cols;
	int size = rows * cols;

	std::unique_ptr<float[]> vals = std::make_unique<float[]>(size);

	float randVal = 0.0f;
	for (int i = 0; i < size; i++) {
		if (rand() % 10 > 5) {
			randVal = 1.0 * (std::rand() % 100) / 100;
		}
		else {
			randVal = -1.0 * (std::rand() % 100) / 100;
		}
		vals[i] = randVal;
	}

	std::unique_ptr<Matrix> ret_matrix = std::make_unique<Matrix>(vals, shape);

	return ret_matrix;
}
