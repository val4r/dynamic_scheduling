using JuMP
using HiGHS

function add_workload_constraint(model::Model, job_window::Vector{Int64}, duration_window::Vector{Int64}, workload_distribution::String = "even")
    K_w = size(model[:R])[2]
    T_w = size(model[:R])[3]
    #FIXME: WC is now global variable, should be passed as parameter!!!
    if workload_distribution == "even"
        for (i,j) in enumerate(job_window)
            for t in 1:T_w
                for k in 1:K_w
                    #NOTICE: j: job index, i: index of job in vector. i has to be used accessing P_w
                    #Model variables can be accessed with j.
                    @constraint(model, model[:R][j,k,t] == WC[j,k]*model[:X][j,t]/duration_window[i]) #equation 11 (even workload distribution)
                end
            end
        end
    elseif workload_distribution == "free"
        for i in job_window
            for k in 1:K_w
                @constraint(model, sum(model[:R][i,k,t] for t in 1:T_w) == WC[i,k]) #equation 9 (free workload distribution)
                for t in 1:T_w
                    @constraint(model, model[:R][i,k,t] <= (M*model[:X][i,t]))  #equation 10
                end
            end
        end
    else
        print("error")
    end
    return model
end


#Creates "general" precedence constraints in modified model 
function all_precedence_constraints(data::DataFrame)
    function order_precedences(jobs_in_order::Vector{Int64})
        precedence_constraints = Dict{Int64, Int64}()
        for i in 1:(length(jobs_in_order)-1)
            job = jobs_in_order[i]
            successor_job = jobs_in_order[i+1]
            precedence_constraints[job] = successor_job
        end
        return precedence_constraints
    end
    
    N_order = maximum(data.Order)
    all_constraints = Dict{Int64, Int64}()
    for order in 1:N_order
        jobs = subset(data, :Order => ByRow(x -> x == order)).Job
        precedence = order_precedences(jobs)
        merge!(all_constraints, precedence)
    end
    return all_constraints
end

function add_timing_temp_constraints(model::Model, job_window::Vector{Int64}, start_time::Dict{Int64, Int64}, precedence_consts::Dict{Int64, Int64}, timing_template::String = "fixed")
    #FIXME: GLOBAL VARIABLES ARE USED NOW:
        #I, P (this should also be changed to dict..), 
    all_jobs = collect(keys(precedence_consts)) #Those jobs which HAVE successors
    #HUOM! JOS KAPPA ON LIIAN PIENI JA TÖITÄ KERTYY TYÖIKKUNAAN MAKSIMIT, OSA SEURAAJISTA VOI OLLA VIELÄ S_a:ssa!!!! TÄLLÖIN EI PYSTY ASETTAMAAN EDELTÄVYYSRAJOITETTA!! TODO: tän vois vaikka korjata tai jotain...
    if timing_template == "fixed" #finish time of predecessor == starting time of successor
        for job in all_jobs
            successor = precedence_consts[job]
            if (job in job_window) && (successor in job_window) #even if job is in job window, it successor might not be, if job windows size is restricted
                @constraint(model, model[:C][job] == model[:C][successor] - P[successor]) 
            elseif (job ∉ job_window) && (successor in job_window)
                @constraint(model, (start_time[job] + P[job]) == model[:C][successor] - P[successor]) 
            else
                #if job nor its successor is in job_window, there is no need for constraints
            end
        end
    elseif timing_template == "free"
        for job in all_jobs
            successor = precedence_consts[job]
            if job in job_window
                @constraint(model, model[:C][job] <= model[:C][successor] - P[successor]) #if job is in job window, so will its successor also be
            elseif job ∉ job_window && successor in job_window
                @constraint(model, (start_time[job] + P[job]) <= model[:C][successor] - P[successor]) 
            else 
                #if job nor its successor is in job_window, there is no need for constraints
            end
        end
    else
        print("error")
    end
    
    return model
end


#Finds jobs which have already been scheduled in job window
#i.e. finds keys for which value is less than 100 in input dict.
#(starting time of jobs are initialized at 100)
#Input:
    #S_w: job window, Vector{Int64}
    #scheduled_starts: Starting time of different jobs, Dict{Int64, Int64}
#Output:
    #scheduled: Scheduled jobs in job window, Vector{Int64}
function find_scheduled_jobs(S_w::Vector{Int64}, scheduled_starts::Dict{Int64, Int64})
    all_scheduled = [key for (key, value) in scheduled_starts if value < 100]
    scheduled = intersect(all_scheduled, S_w)
    return scheduled
end

"DEPRECATED STARTS"
#Jobs which have started but not yet finished
#Reminder: finish time is next timestep after last timestep when job is ongoing
#=function find_ongoing_jobs(timestep::Int64, job_starts::Dict{Int64, Int64}, job_finish::Dict{Int64, Int64})
    all_started = [key for (key, value) in job_starts if value <= timestep]
    all_not_finished = [key for (key, value) in job_finish if value > timestep]
    ongoing = intersect(all_started, all_not_finished)
    return ongoing
end=#
"DEPRECATED ENDS"


#Creates constraints that prevents rescheduling already scheduled jobs
#Used when rescheduling strategy is Frozen/Fixed
#Input:
    #model: The model to which constraints are added, Model
    #scheduled_jobs: Jobs which have been once scheduled and are in job window, Vector{Int64}
    #scheduled_starts: Starting times given this schedule, Dict{Int64, Int64}
    #durations: lead time of jobs, Dict{Int64, Int64}
#Output:
    #model: The model with added constraints
function fix_scheduled_jobs(model::Model, scheduled_jobs::Vector{Int64}, scheduled_starts::Dict{Int64, Int64}, durations::Dict{Int64, Int64})
    for job in scheduled_jobs
        #TODO: TARKISTA!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        @constraint(model, (model[:C][job] - scheduled_starts[job] - durations[job]) == 0)        
    end
    return model
end

#Creates constraints allows postponing rescheduling
#i.e. new starting time can be larger or equal to previous starting time
#and not closer to the deadline than ???
#Input:
    #model: The model to which constraints are added, Model
    #scheduled_jobs: Jobs which have been once scheduled and are in job window, Vector{Int64}
    #scheduled_starts: Starting times given this schedule, Dict{Int64, Int64}
    #durations: lead time of jobs, Dict{Int64, Int64}
#Output:
    #model: The model with added constraints    
function postpone_scheduled_jobs(model::Model, scheduled_jobs::Vector{Int64}, scheduled_starts::Dict{Int64, Int64}, durations::Dict{Int64, Int64}, due_dates::Dict{Int64, Int64})
    for job in scheduled_jobs
        #TODO: TARKISTA!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        @constraint(model, model[:C][job] - scheduled_starts[job] - durations[job] >= 0)
        #TODO: distance to deadline-constraints
    end
    return model
end

function create_job_window_data(S_w::Vector{Int64}, I::Int64, P::Vector{Int64}, D::Vector{Int64}, A::Vector{Int64}, WC::Matrix{Float64}, OA::Vector{Int64})
    P_w = P[S_w]
    D_w = D[S_w]
    A_w = A[S_w]
    OA_w = OA[S_w]
    WC_w = WC[S_w,:]
    return P_w, D_w, A_w, WC_w, OA_w
end

#TODO: Parameter objects
function create_job_window_model(S_w, P_w, D_w, A_w, WC_w, OA_w, job_start::Dict{Int64, Int64}, capacity::Vector{Int64}, timestep::Int64, R_auxiliary::Array{Float64, 3}, prec_consts::Dict{Int64, Int64}, workload_distribution::String = "even", timing_template::String = "fixed", forward_planning::Bool = false, backward_planning::Bool = false, planning_const = 10)
    model = Model(HiGHS.Optimizer)
    #FIXME: GLOBAL VARIABLES ARE USED NOW:
        #K, 
        #T
        #I
        #P
    #TODO: Vectors could also be replaced with dictionaries to prevent accidents with indexing and orders...
    #TODO: Metaprogramming way of passing constraints as parameters
    #Variables:
    @variable(model, C[S_w] >= 0) #Completion times
    @variable(model, R[S_w, 1:K, 1:T] >=0) #Resource workloads
    @variable(model, tardiness[S_w] >= 0) #Tardiness of jobs
    @variable(model, Max_tardiness >= 0) #Tardiness of job with largest tardiness
    @variable(model, c[S_w, 1:T], Bin) #Job completion
    @variable(model, X[S_w, 1:T], Bin) #1 if work i is ongoing
    #Constraints:
    #"Constant" constraints are defined explicitly here,
    #For model "parameter" constraints auxiliary functions are used

    #equation 2
    for i in S_w
        @constraint(model, sum(c[i, t] for t in 1:T) == 1)
    end
    #equation 3
    for i in S_w
        @constraint(model, sum(t*c[i,t] for t in 1:T) == C[i])
    end
    
    #equation 5
    #TODO: TARKISTA!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    for i in S_w
        @constraint(model, C[i] - P[i] >= A[i])
    end
    
    #Capacity constraint: Capacity of any machine shall not be exceeded at any time step
    for t in 1:T
        for k in 1:K
            @constraint(model, (capacity[k] - sum(R[i, k, t] for i in S_w) - sum(R_auxiliary[ii,k,t] for ii in 1:I) ) >= 0) #ii can loop over all jobs because
            #R_auxiliary is non-zero only for ongoing jobs.
        end
    end
    
    #Fixed version
    for i in S_w
        for t in 1:T
            @constraint(model, X[i,t] == sum(c[i,u] for u in (t+1):(t+P[i]) if u <= T))
        end
    end
    
    #constraint that makes sure that starting time of job is not placed in the history
    #i.e. starting times of rescheduled jobs are larger or equal to present time
    #TODO: TARKISTA!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    for i in S_w
        @constraint(model, C[i] - P[i] >= timestep)
    end

    #Tardiness constraint:
    #TODO: TARKISTA!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    for i in S_w
        @constraint(model,  C[i] - D[i] <= tardiness[i])
    end

    #Max tardiness:
    for i in S_w
        @constraint(model, Max_tardiness >= tardiness[i])
    end

    #TODO: Aseta läpäisyaikarajoite: 2 x minimitoimitusaika
    for i in S_w
        @constraint(model, C[i] <= (D[i]-A[i] .+ 1)*5/1.5)
    end
    
    #workload distribution
    model = add_workload_constraint(model, S_w, P_w, workload_distribution)
    #timing template
    model = add_timing_temp_constraints(model, S_w, job_start, prec_consts, timing_template)


    #TODO: lisää tähän myös myöhästymien summa
    @objective(model, Min, 0.6 * Max_tardiness + 0.4 * sum(tardiness[i] for i in S_w))
    
    return model
end