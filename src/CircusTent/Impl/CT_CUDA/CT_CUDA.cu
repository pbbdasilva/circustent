/*
 * _CT_CUDA_CU_
 *
 * Copyright (C) 2017-2021 Tactical Computing Laboratories, LLC
 * All Rights Reserved
 * contact@tactcomplabs.com
 *
 * See LICENSE in the top level directory for licensing details
 */

#include "CT_CUDA.cuh"
#ifdef _CT_CUDA_CUH_

CT_CUDA::CT_CUDA(CTBaseImpl::CTBenchType B, CTBaseImpl::CTAtomType A) :
    CTBaseImpl("CUDA", B, A),
    Array(nullptr),
    Idx(nullptr),
    d_Array(nullptr),
    d_Idx(nullptr),
    memSize(0),
    pes(0),
    iters(0),
    elems(0),
    stride(0),
    deviceID(-1),
    deviceCount(0),
    blocksPerGrid(-1),
    threadsPerBlock(-1)
    {}

CT_CUDA::~CT_CUDA() {}

bool CT_CUDA::PrintCUDADeviceProperties(int deviceID, int deviceCount) {
    cudaGetDeviceCount(&deviceCount);
    std::cout << "\nNumber of CUDA enabled devices detected: " << deviceCount << std::endl;
    if (getenv("CUDA_VISIBLE_DEVICES") == nullptr) {
        std::cout << "CUDA_VISIBLE_DEVICES environment variable not set, defaulting to cudaSetDevice(1)" << std::endl;
        deviceID = cudaSetDevice(1);
    }

    if (!deviceID && getenv("CUDA_VISIBLE_DEVICES") == nullptr) {
        std::cout << "No target devices detected!" << std::endl;
        return false;
    }
    return true;
}

bool CT_CUDA::ParseCUDAOpts(int argc, char **argv) {
    for (int i=1; i < argc; i++) {
        std::string s(argv[i]);

        if ( (s=="-bpg") || (s=="-blocks") || (s=="--blocks") ) {
            if ( i+1 > (argc-1) ) {
                std::cout << "Error: --blocks requires an argument" << std::endl;
                return false;
            }
            std::string P(argv[i+1]);
            blocksPerGrid = atoi(P.c_str());
            i++;
        }
        else if ((s=="-tpb") || (s=="-threads") || (s=="--threads")) {
            if ( i+1 > (argc-1) ) {
                std::cout << "Error: --threads requires an argument" << std::endl;
                return false;
            }
            std::string P(argv[i+1]);
            threadsPerBlock = atoi(P.c_str());
            i++;
        }
    }

    // sanity check the options
    if ( blocksPerGrid <= 0 ) {
        std::cout << "Error: --blocks must be greater than 0" << std::endl;
        return false;
    }
    if ( threadsPerBlock <= 0 ) {
        std::cout << "Error: --threads must be greater than 0" << std::endl;
        return false;
    }

    return true;
}

bool CT_CUDA::AllocateData(uint64_t m, uint64_t p, uint64_t i, uint64_t s) {
    // save the data
    memSize = m;
    pes = p;
    iters = i;
    stride = s;
    uint64_t idxMemSize = 2 * memSize;

    // check args
    if ( pes == 0 ) {
        std::cout << "CT_CUDA::AllocateData: `pes` cannot be 0" << std::endl;
        return false;
    }
    if ( iters == 0 ) {
        std::cout << "CT_CUDA::AllocateData `iters` cannot be 0" << std::endl;
        return false;
    }
    if ( stride == 0 ) {
        std::cout << "CT_CUDA::AllocateData `stride` cannot be 0" << std::endl;
        return false;
    }

    // calculate the number of elements
    elems = (memSize/8);
    uint64_t idxElems = (idxMemSize/8);

    // test to see whether we'll stride out of bounds
    uint64_t end = (blocksPerGrid * iters * stride) - stride;
    if ( end >= elems ) {
        std::cout << "CT_CUDA::AllocateData : `Array` is not large enough for blocksPerGrid="
        << blocksPerGrid << "; iters=" << iters << "; stride=" << stride << std::endl;
        return false;
    }

    // Allocate arrays on the host  
    Array = (uint64_t *) malloc(memSize);
    if ( Array == nullptr ) {
        std::cout << "CT_CUDA::AllocateData : 'Array' could not be allocated" << std::endl;
        free(Array);
        return false;
    }

    Idx = (uint64_t *) malloc(idxMemSize);
    if ( Idx == nullptr ) {
        std::cout << "CT_CUDA::AllocateData : 'Idx' could not be allocated" << std::endl;
        free(Array);
        free(Idx);
        return false;
    }

    // Randomize the arrays on the host
    srand(time(NULL));
    if ( this->GetBenchType() == CT_PTRCHASE ) {
        for ( unsigned i = 0; i < idxElems; i++ ) {
            Idx[i] = (uint64_t)(rand()%(idxElems - 1));
        }
    }
    else {
        for ( unsigned i = 0; i < elems; i++ ) {
            Idx[i] = (uint64_t)(rand()%(elems - 1));
        }
    }
    for ( unsigned i=0; i<elems; i++ ) {
        Array[i] = (uint64_t)(rand());
    }

    // allocate data on the target device
    if ( cudaMalloc(&d_Array, memSize) != cudaSuccess ) {
        std::cout << "CT_CUDA::AllocateData : 'd_Array' could not be allocated on device" << std::endl;
        cudaFree(d_Array);
        free(Array);
        free(Idx);
        return false;
    }

    if ( cudaMalloc(&d_Idx, idxMemSize) != cudaSuccess ) {
        std::cout << "CT_CUDA::AllocateData : 'd_Idx' could not be alloced on device" << std::endl;
        cudaFree(d_Array);
        cudaFree(d_Idx);
        free(Array);
        free(Idx);
        return false;
    }


    // copy arrays from host to target device
    if ( cudaMemcpy(d_Array, Array, memSize, cudaMemcpyHostToDevice) != cudaSuccess ) {
        std::cout << "CT_CUDA::AllocateData : 'd_Array' could not be copied to device" << std::endl;
        cudaFree(d_Array);
        cudaFree(d_Idx);
        free(Array);
        free(Idx);
        return false;
    }


    if ( cudaMemcpy(d_Idx, Idx, idxMemSize, cudaMemcpyHostToDevice) != cudaSuccess ) {
        std::cout << "CT_CUDA::AllocateData : 'd_Idx' could not be copied to device" << std::endl;
        cudaFree(d_Array);
        cudaFree(d_Idx);
        free(Array);
        free(Idx);
        return false;
    }

    return true;
}

bool CT_CUDA::Execute(double &Timing, double &GAMS) {

    CTBaseImpl::CTBenchType BType   = this->GetBenchType(); // benchmark type
    CTBaseImpl::CTAtomType  AType   = this->GetAtomType();  // atomic type
    double StartTime = 0.; // start time
    double EndTime   = 0.; // end time
    double OPS       = 0.; // billions of operations

    // determine benchmark type and launch the desired kernel
    if ( BType == CT_RAND ) {
        switch ( AType ) {
            case CT_ADD:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                RAND_ADD<<< blocksPerGrid, threadsPerBlock >>>( d_Array, d_Idx, iters, pes );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(1, iters, blocksPerGrid);
                break;
            case CT_CAS:
                StartTime = this->MySecond();
                RAND_CAS<<< blocksPerGrid, threadsPerBlock >>>( d_Array, d_Idx, iters, pes );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(1, iters, blocksPerGrid);
                break;
            default:
                this->ReportBenchError();
                return false;
                break;
        }
    }
    else if ( BType == CT_STRIDE1 ) {
        switch( AType ) {
            case CT_ADD:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                STRIDE1_ADD<<< blocksPerGrid, threadsPerBlock >>>( d_Array, iters, pes );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(1, iters, blocksPerGrid);
                break;
            case CT_CAS:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                STRIDE1_CAS<<< blocksPerGrid, threadsPerBlock >>>( d_Array, iters, pes );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(1, iters, blocksPerGrid);
                break;
            default:
                this->ReportBenchError();
                return false;
                break;
        }
    }
    else if ( BType == CT_STRIDEN ) {
        switch( AType ) {
            case CT_ADD:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                STRIDEN_ADD<<< blocksPerGrid, threadsPerBlock >>>( d_Array, d_Idx, iters, pes, stride );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(1, iters, blocksPerGrid);
                break;
            case CT_CAS:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                STRIDEN_CAS<<< blocksPerGrid, threadsPerBlock >>>( d_Array, d_Idx, iters, pes, stride );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(1, iters, blocksPerGrid);
                break;
            default:
                this->ReportBenchError();
                return false;
                break;
        }
    }
    else if ( BType == CT_PTRCHASE ) {
        switch( AType ) {
            case CT_ADD:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                PTRCHASE_ADD<<< blocksPerGrid, threadsPerBlock >>>( d_Array, d_Idx, iters, pes );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(1, iters, blocksPerGrid);
                break;
            case CT_CAS:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                PTRCHASE_CAS<<< blocksPerGrid, threadsPerBlock >>>( d_Array, d_Idx, iters, pes );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(1, iters, blocksPerGrid);
                break;
            default:
                this->ReportBenchError();
                return false;
                break;
        }
    }
    else if ( BType == CT_SG ) {
        switch( AType ) {
            case CT_ADD:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                SG_ADD<<< blocksPerGrid, threadsPerBlock >>>( d_Array, d_Idx, iters, pes );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(4, iters, blocksPerGrid);
                break;
            case CT_CAS:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                SG_CAS<<< blocksPerGrid, threadsPerBlock >>>( d_Array, d_Idx, iters, pes );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(4, iters, blocksPerGrid);
                break;
            default:
                this->ReportBenchError();
                return false;
                break;
        }
    }
    else if ( BType == CT_CENTRAL ) {
        switch( AType ) {
            case CT_ADD:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                CENTRAL_ADD<<< blocksPerGrid, threadsPerBlock >>>( d_Array, d_Idx, iters, pes );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(1, iters, blocksPerGrid);
                break;
            case CT_CAS:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                CENTRAL_CAS<<< blocksPerGrid, threadsPerBlock >>>( d_Array, d_Idx, iters, pes );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(1, iters, blocksPerGrid);
                break;
            default:
                this->ReportBenchError();
                return false;
                break;
        }
    }
    else if ( BType == CT_SCATTER ) {
        switch( AType ) {
            case CT_ADD:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                SCATTER_ADD<<< blocksPerGrid, threadsPerBlock >>>( d_Array, d_Idx, iters, pes );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(3, iters, blocksPerGrid);
                break;
            case CT_CAS:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                SCATTER_CAS<<< blocksPerGrid, threadsPerBlock >>>( d_Array, d_Idx, iters, pes );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(3, iters, blocksPerGrid);
                break;
            default:
                this->ReportBenchError();
                return false;
                break;
        }
    }
    else if ( BType == CT_GATHER ) {
        switch( AType ) {
            case CT_ADD:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                GATHER_ADD<<< blocksPerGrid, threadsPerBlock >>>( d_Array, d_Idx, iters, pes );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(3, iters, blocksPerGrid);
                break;
            case CT_CAS:
                cudaDeviceSynchronize();
                StartTime = this->MySecond();
                GATHER_CAS<<< blocksPerGrid, threadsPerBlock >>>( d_Array, d_Idx, iters, pes );
                cudaDeviceSynchronize();
                EndTime   = this->MySecond();
                OPS = this->GAM(3, iters, blocksPerGrid);
                break;
            default:
                this->ReportBenchError();
                return false;
                break;
        }
    }
    else {
        this->ReportBenchError();
        return false;
    }
    
    Timing = this->Runtime(StartTime,EndTime);
    GAMS   = OPS/Timing;

    return true;
}

bool CT_CUDA::FreeData() {
    if ( Array ) {
        free(Array);
    }
    if ( Idx ) {
        free(Idx);
    }
    if ( d_Array ) {
        cudaFree(d_Array);
    }
    if ( d_Idx ) {
        cudaFree(d_Idx);
    }
    return true;
}

#endif // _CT_CUDA_CUH_

// EOF