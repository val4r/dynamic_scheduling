struct JobWindow
    #töiden määrä
    #töiden saapumisaika
    #töiden eräpäivä
    #edeltävyysrajoitteet
    #työkuorma
    #S_w, P_w, D_w, A_w, WC_w, OA_w, job_starts, capacity, t, workload_d, fixed_timing_template
end

struct JobWindowParam
    # capacity::Vector{Int64}, timestep::Int64, workload_distribution::String = "even", timing_template::String = "fixed", forward_planning::Bool = false,   backward_planning::Bool = false, planning_const = 10
    #GLOBAL VARIABLES ARE USED NOW:
        #K, 
        #T
        #I
        #P
end


struct ModelParam
    timing_template::String #timing template
    workload_distribution::String #workload distribution
    rescheduling_strategy::String #rescheduling strategy
    rescheduling_frequency::Int64 #rescheduling frequency
    rescheduling_periodical::Bool #rescheduling periodical
    final_timestep::Int64 #Final time step
    kappa::Int64 #Kappa (number of jobs allowed in job window)
end

struct Order
    #order index
    #job indeces
    #precedence constraints
end

struct RollingHorizonSets
    #S_j
    #S_a
    #S_w
    #S_s
    #S_c
end

#Gather data together to data struct
#=
MITÄ TARVITAAN TALLENTAA SIMULAATIOSTA?
-MALLIN PARAMETRIT
-JOKA AIKAHETKEN TÖIDEN AIKATAULUTUKSET (ALOITUS JA LOPETUS)
-Mallit
-Keinotekoinen kokonainen R-matriisi (resource load)
=#
struct OutputData
    parameters::ModelParam
    starts::Dict{Int64, Dict{Int64, Int64}}
    finishes::Dict{Int64, Dict{Int64, Int64}}
    models::Dict{Int64, Model}
end