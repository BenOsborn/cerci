#include "matrix.cuh"

Matrix::Matrix(std::unique_ptr<float[]>& inMatrix, std::unique_ptr<int[]>& inShape) {
	Matrix::shape = std::make_unique<int[]>(2);
	memcpy(shape.get(), inShape.get(), 2 * sizeof(int));

	Matrix::size = std::make_unique<int>(shape[0] * shape[1]);

	Matrix::matrix = std::make_unique<float[]>(*size);
	memcpy(matrix.get(), inMatrix.get(), *size * sizeof(float));
}

void Matrix::print() {
	for (int i = 0; i < shape[0]; i++) {
		for (int j = 0; j < shape[1]; j++) {
			std::cout << matrix[i * shape[1] + j] << " ";
		}
		std::cout << "\n";
	}
}

std::unique_ptr<Matrix> Matrix::reshape(int rows, int cols) {
	if (rows * cols != *size) throw std::invalid_argument("New matrix size does not match original matrix size!");

	std::unique_ptr<int[]> new_shape = std::make_unique<int[]>(2);
	new_shape[0] = rows;
	new_shape[1] = cols;

	std::unique_ptr<Matrix> ret_matrix = std::make_unique<Matrix>(matrix, new_shape);

	return ret_matrix;
}

__global__
void transposeD(int rows, int cols, float* inVector) {
	int row = blockIdx.y * blockDim.y + threadIdx.y;
	int col = blockIdx.x * blockDim.x + threadIdx.x;
	if ((row < rows) && (col < cols)) inVector[col * rows + row] = inVector[row * cols + col];
}

std::unique_ptr<Matrix> Matrix::transpose() {
	std::unique_ptr<int[]> new_shape = std::make_unique<int[]>(2);
	new_shape[0] = shape[1];
	new_shape[1] = shape[0];

	int bytes = *size * sizeof(float);

	float* dCopy;
	cudaMalloc(&dCopy, bytes);
	cudaMemcpy(dCopy, matrix.get(), bytes, cudaMemcpyHostToDevice);

	Constants constants;
	int grid_rows = (shape[0] + constants.BLOCK_SIZE - 1) / constants.BLOCK_SIZE;
	int grid_cols = (shape[1] + constants.BLOCK_SIZE - 1) / constants.BLOCK_SIZE;
	dim3 dimGrid(grid_cols, grid_rows);
	dim3 dimBlock(constants.BLOCK_SIZE, constants.BLOCK_SIZE);

	transposeD <<< dimGrid, dimBlock >>> (shape[0], shape[1], dCopy);

	std::unique_ptr<float[]> new_matrix = std::make_unique<float[]>(*size);
	cudaMemcpy(new_matrix.get(), dCopy, bytes, cudaMemcpyDeviceToHost);

	std::unique_ptr<Matrix> ret_matrix = std::make_unique<Matrix>(new_matrix, new_shape);

	cudaFree(dCopy);

	return ret_matrix;
}

template <typename Lambda>
__global__
void applyD(int size, float* inVector, Lambda function) {
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index < size) inVector[index] = function(inVector[index]);
}

// I might just have to write this down as a template and then have the ability to parse in arguments as I want oooo that could be a good idea
template <typename Lambda>
std::unique_ptr<Matrix> Matrix::apply(Lambda function) {
	int bytes = *size * sizeof(float);

	float* dCopy;
	cudaMalloc(&dCopy, bytes);
	cudaMemcpy(dCopy, matrix.get(), bytes, cudaMemcpyHostToDevice);

	Constants constants;
	int dimGridX = (*size + constants.THREAD_SIZE - 1) / constants.THREAD_SIZE;
	applyD <<< dimGridX, constants.THREAD_SIZE >>> (*size, dCopy, function);

	std::unique_ptr<float[]> new_matrix = std::make_unique<float[]>(*size);
	cudaMemcpy(new_matrix.get(), dCopy, bytes, cudaMemcpyDeviceToHost);

	std::unique_ptr<Matrix> ret_matrix = std::make_unique<Matrix>(new_matrix, shape);

	cudaFree(dCopy);

	return ret_matrix;
}

std::unique_ptr<Matrix> Matrix::clone() {
	std::unique_ptr<Matrix> ret_matrix = std::make_unique<Matrix>(matrix, shape);
	return ret_matrix;
}

std::unique_ptr<float[]> Matrix::returnMatrix() {
	std::unique_ptr<float[]> ret_matrix = std::make_unique<float[]>(*size);
	memcpy(ret_matrix.get(), matrix.get(), *size * sizeof(float));

	return ret_matrix;
}

std::unique_ptr<int[]> Matrix::returnShape() {
	std::unique_ptr<int[]> ret_shape = std::make_unique<int[]>(2);
	memcpy(ret_shape.get(), shape.get(), 2 * sizeof(unsigned int));
	return ret_shape;
}

int Matrix::returnSize() {
	return *size;
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

	Constants constants;
	int dimGridX = (size + constants.THREAD_SIZE - 1) / constants.THREAD_SIZE;
	addD <<< dimGridX, constants.THREAD_SIZE >>> (size, mat1d, mat2d, mat3d);

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

	Constants constants;
	int grid_rows = (new_shape[0] + constants.BLOCK_SIZE - 1) / constants.BLOCK_SIZE;
	int grid_cols = (new_shape[1] + constants.BLOCK_SIZE - 1) / constants.BLOCK_SIZE;
	dim3 dimGrid(grid_cols, grid_rows);
	dim3 dimBlock(constants.BLOCK_SIZE, constants.BLOCK_SIZE);

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
