### Proximal gradient method
export APALMParams, fit!

type History
    FPR
    tries
end
History() = History(Float64[], Int[])

type APALMParams<:AbstractParams
    stepsize::Float64 # initial stepsize
    max_iter::Int # maximum number of outer iterations
    inner_iter::Int # how many prox grad steps to take on X before moving on to Y (and vice versa)
    abs_tol::Float64 # stop if objective decrease upon one outer iteration is less than this * number of observations
    rel_tol::Float64 # stop if objective decrease upon one outer iteration is less than this * objective value
    min_stepsize::Float64 # use a decreasing stepsize, stop when reaches min_stepsize
    M::Float64 # like a Lipshitz constant: ||\nabla_j f(x^k) - \nabla_j f(x^{k-d})|| <= ||x^k - x^{k-d}|| for any j and for any d=1,...,delay
    delay::Int # length of history
    nb_tries::Int # how many times to try to find a decrease before giving up
end
function APALMParams(stepsize::Number=1.0; # initial stepsize
                        max_iter::Int=100, # maximum number of outer iterations
                        inner_iter::Int=1, # how many prox grad steps to take on X before moving on to Y (and vice versa)
                        abs_tol::Number=0.00001, # stop if objective decrease upon one outer iteration is less than this * number of observations
                        rel_tol::Number=0.0001, # stop if objective decrease upon one outer iteration is less than this * objective value
                        min_stepsize::Number=0.01*stepsize, # stop if stepsize gets this small
                        M::Number=1,
                        delay::Int=5,
                        nb_tries::Int=10)
    stepsize = convert(Float64, stepsize)
    return APALMParams(convert(Float64, stepsize), 
                          max_iter, 
                          inner_iter, 
                          convert(Float64, abs_tol), 
                          convert(Float64, rel_tol), 
                          convert(Float64, min_stepsize),
                          convert(Float64, M),
                          delay,
                          nb_tries)
end

### FITTING
function fit!(glrm::GLRM, params::APALMParams;
              ch::ConvergenceHistory=ConvergenceHistory("ProxGradGLRM"), 
              history = History(),
              verbose=true,
              kwargs...)
    ### initialization
    A = glrm.A # rename these for easier local access
    losses = glrm.losses
    rx = glrm.rx
    ry = glrm.ry
    X = glrm.X; Y = glrm.Y
    # check that we didn't initialize to zero (otherwise we will never move)
    if vecnorm(Y) == 0 
        Y = .1*randn(k,d) 
    end
    k = glrm.k
    m,n = size(A)

    # find spans of loss functions (for multidimensional losses)
    yidxs = get_yidxs(losses)
    d = maximum(yidxs[end])
    # check Y is the right size
    if d != size(Y,2)
        warn("The width of Y should match the embedding dimension of the losses.
            Instead, embedding_dim(glrm.losses) = $(embedding_dim(glrm.losses))
            and size(glrm.Y, 2) = $(size(glrm.Y, 2)). 
            Reinitializing Y as randn(glrm.k, embedding_dim(glrm.losses).")
            # Please modify Y or the embedding dimension of the losses to match,
            # eg, by setting `glrm.Y = randn(glrm.k, embedding_dim(glrm.losses))`")
        glrm.Y = randn(glrm.k, d)
    end

    # initialize history
    delay = params.delay
    Xhist = fill(Array(Float64, size(X)), delay)
    for Xh in Xhist
        copy!(Xh, X)
    end
    Yhist = fill(Array(Float64, size(Y)), delay)
    for Yh in Yhist
        copy!(Yh, Y)
    end
    Xprev = copy(X)
    Yprev = copy(Y)

    XY = Array(Float64, (m, d))
    gemm!('T','N',1.0,X,Y,0.0,XY) # XY = X' * Y initial calculation

    # step size (will be scaled below to ensure it never exceeds 1/\|g\|_2 or so for any subproblem)
    alpharow = params.stepsize*ones(m)
    alphacol = params.stepsize*ones(n)
    # stopping criterion: stop when decrease in objective < tol, scaled by the number of observations
    scaled_abs_tol = params.abs_tol * mapreduce(length,+,glrm.observed_features)

    # alternating updates of X and Y
    if verbose println("Fitting GLRM") end
    update!(ch, 0, objective(glrm, X, Y, XY, yidxs=yidxs))
    t = time()
    steps_in_a_row = 0
    # gradient wrt columns of X
    g = zeros(k)
    # gradient wrt column-chunks of Y
    G = zeros(k, d)
    # rowwise objective value
    obj_by_row = zeros(m)
    # columnwise objective value
    obj_by_col = zeros(n)

    # cache views for better memory management
    # first a type hack
    @compat typealias Yview Union{ContiguousView{Float64,1,Array{Float64,2}}, 
                                  ContiguousView{Float64,2,Array{Float64,2}}}
    # make sure we don't try to access memory not allocated to us
    @assert(size(Y) == (k,d))
    @assert(size(X) == (k,m))
    # views of the columns of X corresponding to each example
    ve = ContiguousView{Float64,1,Array{Float64,2}}[view(X,:,e) for e=1:m]
    # views of the column-chunks of Y corresponding to each feature y_j
    # vf[f] == Y[:,f]
    vf = Yview[view(Y,:,yidxs[f]) for f=1:n]
    # views of the column-chunks of G corresponding to the gradient wrt each feature y_j
    # these have the same shape as y_j
    gf = Yview[view(G,:,yidxs[f]) for f=1:n]

    # working variables
    newX = copy(X)
    newY = copy(Y)
    newve = ContiguousView{Float64,1,Array{Float64,2}}[view(newX,:,e) for e=1:m]
    newvf = Yview[view(newY,:,yidxs[f]) for f=1:n]

    for i=1:params.max_iter
# STEP 1: X update
        # XY = X' * Y this is computed before the first iteration
        
        # crazy APALM stuff!
        M = delay*(i^.5) # try also M = 2*delay * ||grad_{j_k, k} - grad_{j_k, k-d_k}||/ ||x^k - x^{k-d_k}||
        push!(history.tries, 0)
        avg = mean(history.FPR[max(length(history.FPR) - 2*delay, 1):end]) # why times 2? b/c of X and Y updates
        copy!(Xprev, X)

        # for inneri=1:params.inner_iter
        while history.tries[end] == 0 || ((avg > vecnorm(X - Xprev)^2) && (history.tries[end] < params.nb_tries))
            Y_old = Yhist[sample(1:delay)]
            L_1 = max(norm(Y_old)^2, .0001);
            gamma = 1/(L_1 + M);
            if history.tries[end] > 0 # unwind the changes b/c they didn't work
                copy!(X, Xprev)
            end
            gemm!('T','N',1.0,X,Y_old,0.0,XY) # Recalculate XY using the stale Y        

            for e=1:m # sample(1:m) # for every example x_e == ve[e]
                scale!(g, 0) # reset gradient to 0
                # compute gradient of L with respect to Xᵢ as follows:
                # ∇{Xᵢ}L = Σⱼ dLⱼ(XᵢYⱼ)/dXᵢ
                for f in glrm.observed_features[e]
                    # but we have no function dLⱼ/dXᵢ, only dLⱼ/d(XᵢYⱼ) aka dLⱼ/du
                    # by chain rule, the result is: Σⱼ (dLⱼ(XᵢYⱼ)/du * Yⱼ), where dLⱼ/du is our grad() function
                    curgrad = grad(losses[f],XY[e,yidxs[f]],A[e,f])
                    if isa(curgrad, Number)
                        axpy!(curgrad, vf[f], g)
                    else
                        gemm!('N', 'T', 1.0, vf[f], curgrad, 1.0, g)
                    end
                end
                # take a proximal gradient step to update ve[e]
                l = length(glrm.observed_features[e]) + 1 # if each loss function has lipshitz constant 1 this bounds the lipshitz constant of this example's objective
                obj_by_row[e] = row_objective(glrm, e, ve[e]) # previous row objective value
                while alpharow[e] > params.min_stepsize
                    stepsize = alpharow[e]/l 
                    # newx = prox(rx, ve[e] - stepsize*g, stepsize) # this will use much more memory than the inplace version with linesearch below
                    ## gradient step: Xᵢ += -(α/l) * ∇{Xᵢ}L
                    axpy!(-stepsize,g,newve[e])
                    ## prox step: Xᵢ = prox_rx(Xᵢ, α/l)
                    prox!(rx,newve[e],stepsize)
                    if row_objective(glrm, e, newve[e]) < obj_by_row[e]
                        copy!(ve[e], newve[e])
                        alpharow[e] *= 1.05
                        break
                    else # the stepsize was too big; undo and try again only smaller
                        copy!(newve[e], ve[e])
                        alpharow[e] *= .7
                        if alpharow[e] < params.min_stepsize
                            alpharow[e] = params.min_stepsize * 1.1
                            break
                        end                
                    end
                end
            end # for e=1:m
            # crazy APALM stuff
            history.tries[end]+=1
        end # while

        # crazy APALM stuff! update history
        push!(history.FPR, vecnorm(Xprev - X)^2)
        copy!(Xhist[(i-1)%delay+1], X)

# STEP 2: Y update
        # crazy APALM stuff!
        push!(history.tries, 0)
        avg = mean(history.FPR[max(length(history.FPR) - 2*delay, 1):end]) # why times 2? b/c of X and Y updates
        copy!(Yprev, Y)

        # for inneri=1:params.inner_iter
        while history.tries[end] == 0 || ((avg > vecnorm(Y - Yprev)^2) && (history.tries[end] < params.nb_tries))
            X_old = Xhist[sample(1:delay)]
            L_1 = max(norm(X_old)^2, .0001);
            gamma = 1/(L_1 + M);
            if history.tries[end] > 0 # unwind the changes b/c they didn't work
                copy!(Y, Yprev)
            end
            gemm!('T','N',1.0,X_old,Y,0.0,XY) # Recalculate XY using the stale X        
            scale!(G, 0)
            for f=1:n # sample(1:n)
                # compute gradient of L with respect to Yⱼ as follows:
                # ∇{Yⱼ}L = Σⱼ dLⱼ(XᵢYⱼ)/dYⱼ 
                for e in glrm.observed_examples[f]
                    # but we have no function dLⱼ/dYⱼ, only dLⱼ/d(XᵢYⱼ) aka dLⱼ/du
                    # by chain rule, the result is: Σⱼ dLⱼ(XᵢYⱼ)/du * Xᵢ, where dLⱼ/du is our grad() function
                    curgrad = grad(losses[f],XY[e,yidxs[f]],A[e,f])
                    if isa(curgrad, Number)
                        axpy!(curgrad, ve[e], gf[f])
                    else
                        gemm!('N', 'N', 1.0, ve[e], curgrad, 1.0, gf[f])
                    end
                end
                # take a proximal gradient step
                l = length(glrm.observed_examples[f]) + 1
                obj_by_col[f] = col_objective(glrm, f, vf[f])
                while alphacol[f] > params.min_stepsize
                    stepsize = alphacol[f]/l
                    # newy = prox(ry[f], vf[f] - stepsize*gf[f], stepsize)
                    ## gradient step: Yⱼ += -(α/l) * ∇{Yⱼ}L
                    axpy!(-stepsize,gf[f],newvf[f]) 
                    ## prox step: Yⱼ = prox_ryⱼ(Yⱼ, α/l)
                    prox!(ry[f],newvf[f],stepsize)
                    new_obj_by_col = col_objective(glrm, f, newvf[f])
                    if new_obj_by_col < obj_by_col[f]
                        copy!(vf[f], newvf[f])
                        alphacol[f] *= 1.05
                        obj_by_col[f] = new_obj_by_col
                        break
                    else
                        copy!(newvf[f], vf[f])
                        alphacol[f] *= .7
                        if alphacol[f] < params.min_stepsize
                            alphacol[f] = params.min_stepsize * 1.1
                            break
                        end
                    end
                end
            end # for e=1:m
            # crazy APALM stuff
            history.tries[end]+=1
        end # while

        # crazy APALM stuff! update history
        push!(history.FPR, vecnorm(Yprev - Y)^2)
        copy!(Yhist[(i-1)%delay+1], Y)

# STEP 3: Record objective
        obj = sum(obj_by_col)
        t = time() - t
        update!(ch, t, obj)
        t = time()
# STEP 4: Check stopping criterion
        obj_decrease = ch.objective[end-1] - obj
        if i>10 && (obj_decrease < scaled_abs_tol || obj_decrease/obj < params.rel_tol)
            break
        end
        if verbose && i%10==0 
            println("Iteration $i: objective value = $(ch.objective[end])") 
        end
    end

    return glrm.X, glrm.Y, ch
end