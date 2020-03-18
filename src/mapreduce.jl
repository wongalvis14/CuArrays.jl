## COV_EXCL_START

# TODO
# - serial version for lower latency
# - block-stride loop to delay need for second kernel launch

# Reduce a value across a warp
@inline function reduce_warp(op, val)
    # offset = CUDAnative.warpsize() ÷ 2
    # while offset > 0
    #     val = op(val, shfl_down_sync(0xffffffff, val, offset))
    #     offset ÷= 2
    # end

    # Loop unrolling for warpsize = 32
    val = op(val, shfl_down_sync(0xffffffff, val, 16, 32))
    val = op(val, shfl_down_sync(0xffffffff, val, 8, 32))
    val = op(val, shfl_down_sync(0xffffffff, val, 4, 32))
    val = op(val, shfl_down_sync(0xffffffff, val, 2, 32))
    val = op(val, shfl_down_sync(0xffffffff, val, 1, 32))

    return val
end

# Reduce a value across a block, using shared memory for communication
@inline function reduce_block(op, val::T, neutral, shuffle::Val{true}) where T
    # shared mem for 32 partial sums
    shared = @cuStaticSharedMem(T, 32)  # NOTE: this is an upper bound; better detect it

    wid, lane = fldmod1(threadIdx().x, CUDAnative.warpsize())

    # each warp performs partial reduction
    val = reduce_warp(op, val)

    # write reduced value to shared memory
    if lane == 1
        @inbounds shared[wid] = val
    end

    # wait for all partial reductions
    sync_threads()

    # read from shared memory only if that warp existed
    val = if threadIdx().x <= fld1(blockDim().x, CUDAnative.warpsize())
         @inbounds shared[lane]
    else
        neutral
    end

    # final reduce within first warp
    if wid == 1
        val = reduce_warp(op, val)
    end

    return val
end
@inline function reduce_block(op, val::T, neutral, shuffle::Val{false}) where T
    threads = blockDim().x
    thread = threadIdx().x

    # shared mem for a complete reduction
    shared = @cuDynamicSharedMem(T, (2*threads,))
    @inbounds shared[thread] = val

    # perform a reduction
    d = threads>>1
    while d > 0
        sync_threads()
        if thread <= d
            shared[thread] = op(shared[thread], shared[thread+d])
        end
        d >>= 1
    end

    # load the final value on the first thread
    if thread == 1
        val = @inbounds shared[thread]
    end

    return val
end

# Partially reduce an array across the grid. The reduction is partial, with multiple
# blocks `gridDim_reduce` working on reducing data from `A` and writing it to multiple
# outputs in `R`. All elements to be processed can be addressed by the product of the
# two iterators `Rreduce` and `Rother`, where the latter iterator will have singleton
# entries for the dimensions that should be reduced (and vice versa). The output array
# is expected to have an additional dimension with as size the number of reduced values
# for every reduction (i.e. more than one if there's multiple blocks participating).
function partial_mapreduce_grid(f, op, A, R, neutral, Rreduce, Rother, gridDim_reduce, shuffle, reduce_per_thread, stride)
    # decompose the 1D hardware indices into separate ones for reduction (across threads
    # and possibly blocks if it doesn't fit) and other elements (remaining blocks)
    threadIdx_reduce = threadIdx().x
    blockDim_reduce = blockDim().x
    blockIdx_other, blockIdx_reduce = fldmod1(blockIdx().x, gridDim_reduce)

    ireduce = (threadIdx_reduce + (blockIdx_reduce - 1) * blockDim_reduce) * reduce_per_thread
    val = neutral
    for i in 0:reduce_per_thread-1
        ireduce++
        val = op(val, R[ireduce])
    end
                
    # @cuprintln "thread $(threadIdx().x) block $(blockIdx().x): $(Rreduce) $(blockIdx_reduce) $(blockIdx_other)"
    # block-based indexing into the values outside of the reduction dimension
    # (that means we can safely synchronize threads within this block)
    iother = blockIdx_other
    @inbounds if iother <= length(Rother)
        Iother = Rother[iother]

        # load the neutral value
        Iout = CartesianIndex(Tuple(Iother)..., blockIdx_reduce)
        neutral = if neutral === nothing
            R[Iout]
        else
            neutral
        end

        # get a value that should be reduced
#        ireduce = threadIdx_reduce + (blockIdx_reduce - 1) * blockDim_reduce
#=
        val = if ireduce <= length(Rreduce)
            Ireduce = Rreduce[ireduce]
            J = max(Iother, Ireduce)
            f(A[J])
        else
            neutral
        end
        val = op(val, neutral)
=#
        val = reduce_block(op, val, neutral, shuffle)

        # write back to memory
        if threadIdx_reduce == 1
            R[Iout] = val
        end
        @cuprintln "thread $(threadIdx().x) block $(blockIdx().x): ireduce: $(ireduce) iother: $(iother) blockid_r: $(blockIdx_reduce) blockid_o: $(blockIdx_other)"
    end

    return
end

## COV_EXCL_STOP

NVTX.@range function GPUArrays.mapreducedim!(f, op, R::CuArray{T}, A::AbstractArray, init=nothing) where T
    Base.check_reducedims(R, A)
    isempty(A) && return R

    f = cufunc(f)
    op = cufunc(op)

    # be conservative about using shuffle instructions
    shuffle = true
    shuffle &= capability(device()) >= v"3.0"
    shuffle &= T in (Int32, Int64, Float32, Float64, ComplexF32, ComplexF64)
    # TODO: add support for Bool (CUDAnative.jl#420)

    # iteration domain, split in two: one part covers the dimensions that should
    # be reduced, and the other covers the rest. combining both covers all values.
    Rall = CartesianIndices(A)
    Rother = CartesianIndices(R)
    Rreduce = CartesianIndices(ifelse.(axes(A) .== axes(R), Ref(Base.OneTo(1)), axes(A)))
    # NOTE: we hard-code `OneTo` (`first.(axes(A))` would work too) or we get a
    #       CartesianIndices object with UnitRanges that behave badly on the GPU.
    @assert length(Rall) == length(Rother) * length(Rreduce)

    # allocate an additional, empty dimension to write the reduced value to.
    # this does not affect the actual location in memory of the final values,
    # but allows us to write a generalized kernel supporting partial reductions.
    R′ = reshape(R, (size(R)..., 1))

    # determine how many threads we can launch
    args = (f, op, A, R′, init, Rreduce, Rother, 1, Val(shuffle), 256, 1)
    kernel_args = cudaconvert.(args)
    kernel_tt = Tuple{Core.Typeof.(kernel_args)...}
    kernel = cufunction(partial_mapreduce_grid, kernel_tt)
    kernel_config =
        launch_configuration(kernel.fun; shmem = shuffle ? 0 : threads->2*threads*sizeof(T))

    # determine the launch configuration
    dev = device()
    reduce_threads = shuffle ? nextwarp(dev, length(Rreduce)) : nextpow(2, length(Rreduce))
    if reduce_threads > kernel_config.threads
        reduce_threads = shuffle ? prevwarp(dev, kernel_config.threads) : prevpow(2, kernel_config.threads)
    end
    max_reduce_per_thread = 256
    reduce_blocks = cld(length(Rreduce), reduce_threads * max_reduce_per_thread)
    reduce_per_thread = cld(length(Rreduce), reduce_blocks * reduce_threads)
    other_blocks = length(Rother)
    threads, blocks = reduce_threads, reduce_blocks*other_blocks
    shmem = shuffle ? 0 : 2*threads*sizeof(T)

    println("reduce_threads: $reduce_threads")
    println("reduce_blocks: $reduce_blocks")
    println("reduce_per_thread: $reduce_per_thread")

    # perform the actual reduction
    if reduce_blocks == 1
        # we can cover the dimensions to reduce using a single block
	@cuda threads=threads blocks=blocks shmem=shmem partial_mapreduce_grid(
            f, op, A, R′, init, Rreduce, Rother, 1, Val(shuffle), reduce_per_thread, reduce_threads)
    else
        # we need multiple steps to cover all values to reduce
        partial = similar(R, (size(R)..., reduce_blocks))
        if init === nothing
            # without an explicit initializer we need to copy from the output container
            sz = prod(size(R))
            for i in 1:reduce_blocks
                # TODO: async copies (or async fill!, but then we'd need to load first)
                #       or maybe just broadcast since that extends singleton dimensions
                copyto!(partial, (i-1)*sz+1, R, 1, sz)
            end
        end
        @cuda threads=threads blocks=blocks shmem=shmem partial_mapreduce_grid(
            f, op, A, partial, init, Rreduce, Rother, reduce_blocks, Val(shuffle), reduce_per_thread, reduce_threads)

        GPUArrays.mapreducedim!(identity, op, R′, partial, init)
    end

    return R
end
