using PrettyTables
include("visualization_functions.jl")
include("structures.jl")

#Function which can be used for both start and finish dictionaries to convert them to sorted vectors.
#Will be used in save_gantt_charts_to_folder-function
function state_at_time_t(state_T::Dict{Int64, Dict{Int64, Int64}}, t::Int64)
    state_at_t = [state_T[t][k] for k in sort(collect(keys(state_T[t])))]
end

#Creates gantt charts at all timesteps, and saves them as png-files to given folder
#Inputs:
    #all_starts: starting times of jobs for every timestep t, Dict{Int64, Dict{Int64, Int64}}
    #all_finish: finishing times of jobs for every timestep t, Dict{Int64, Dict{Int64, Int64}}
    #I: number of jobs, Int64
    #O: number of orders, Int64
    #T: final time step, Int64
    #freq: rescheduling frequency, Int64
    #folder: folder name ("frozen", "free", "postponement"), String
function save_gantt_charts_to_folder(all_starts, all_finish, I, O, T, freq, folder::String)
    for t in 1:T
        start_times = state_at_time_t(all_starts, t)
        finish_times = state_at_time_t(all_finish, t)
        p = create_dynamic_gantt_chart(start_times, finish_times, I, O, t)
        save("../koodi/kuvat/gantt_charts/$folder/$freq/gantt_plot_$t.png", p)
    end
end

#Calculate objective function (max tardiness) value of the dynamic model. 
#This can't be accessed directly from JuMP-model, because it is solved piecewise.
#Inputs:
    #final_finish_times: finish times of the jobs at the end, Dict{Int64, Int64}
    #duedates: due date of all jobs, Dict{Int64, Int64}
function calculate_dynamic_max_tardiness(final_finish_times::Dict{Int64, Int64}, duedates::Dict{Int64, Int64})
    tards = Dict{Int64, Int64}()
    for job in collect(keys(final_finish_times))
        tard = max(0, final_finish_times[job] - duedates[job])
        tards[job] = tard
    end
    return findmax(tards)[1]
end

#Save simulation data to file
#Input:
    #folder_name: folder into which data is saved, String
    #output_data: custom data struct containing all the necessary data from simulation run, OutputData
function save_data(folder_name::String, output_data::OutputData)
    model_params = output_data.parameters
    filename = string(model_params.timing_template, "_", model_params.workload_distribution, "_", model_params.rescheduling_strategy, "_",   model_params.rescheduling_frequency)
    folder_and_file = string(folder_name, "/", filename, ".jld2")
    jldsave(folder_and_file; output_data)
end


function workload_t(resource_load_T::Dict{Any, Any}, freq::Int64, T::Int64)
    #Algoritmi kokonaiskuvan luomiseksi:
    #Step 1: Alusta dictionary "load_in_time", jossa avain jokaiselle työlle, ja arvona on 1xT-vektori, johon tallennetaan työn aiheuttama kuorma kunakin ajan hetkenä
    #Step 2: Käydään jokaisen optimoidun mallin R-vektori. Päivitetään kunkin mallissa aikataulutetun työn load_in_time-vektori. 
    #Step 3: Näin muodostunut load_in_time vektori kuvaa kokonaisen mallin lopullisen aikataulutuksen, sekä sen miten töiden kuormat jakautuvat
    load_in_time = Dict(i => zeros(T) for i in 1:I)
    schedulings = [t for t in 1:T if t % freq == 0 || t == 1]
    for step in schedulings
        arr = resource_load_T[step]
        jobs_dict = (arr).lookup[1].data
        for job in jobs_dict
            job_id = job[1] #number identicating the unique job
            job_idx = job[2] #position of job in array
            #load_in_time[job] = 
            load_in_time[job_id] = vec(sum(value.((arr).data[job_idx,:,:]), dims=1))
        end
    end
    sorted_load_in_time = sort(collect(load_in_time), by=x->x[1])
    return sorted_load_in_time
end

#ALGORITMI ALKANEIDEN TÖIDEN KUORMITUKSEN SELVITTÄMISEKSI:
#MOTIVAATIO: KUN TYÖT AIKATAULUTETAAN, YKSI RAJOITE ON KUNKIN AJANHETKEN JA RESURSSIN KAPASITEETTI. TYÖ VOIDAAN AIKATAULUTTAA
#AJANHETKELLE T RESURSSILLE K, JOS TYÖN KUORMAN, SEKÄ RESURSSILLA KÄYNNISSÄ OLEVIEN TÖIDEN KUORMIEN SUMMA ON PIENEMPI KUIN RESURSSIN KAPASITEETTI 
#(JOKAISELLA AJANHETKELLÄ t, ELI TÄYTYY OTTAA HUOMIOON TULEVATKIN AJANHETKET)
#ON SIIS TARPEEN SELVITTÄÄ: MITKÄ TYÖT OVAT KÄYNNISSÄ AIKATAULUTUSAJANHETKELLÄ, SEKÄ NÄIDEN AIHEUTTAMA KUORMA 

#ALGORITMI:
#STEP 1:
#SELVITÄ KÄYNNISSÄ OLEVAT TYÖT UUDELLEENAIKATAULUTUSAJANHETKELLÄ t
#STEP 2: 
#OTA EDELLISTEN AIKASTEPPIEN resource_load_T, ETSI VIIMEISIN T_R, JOKA SISÄLTÄÄ KÄYNNISSÄ OLEVAN TYÖN I_O, OTA resource_load_T[T_R][I_O, :, :]
#STEP 3:
#MUODOSTA R_ongoing, JOKA ON MUODOLTAAN SAMANLAINEN KUIN model[:R], MUTTA SISÄLTÄÄ KÄYNNISSÄ OLEVIEN TÖIDEN I_ongoing KUORMAT RESURSSEILLE 1:K 
#AJANHETKILLÄ 1:T. KÄYTÄ TÄHÄN RESOURCE_LOAD_T-MUUTTUJAA.
#STEP 4:
#LUO MALLIN KAPASITEETTIRAJOITUKSET SITEN ETTÄ UUSIEN TÖIDEN JA KÄYNNISSÄ OLEVIEN KUORMIEN SUMMA PIENEMPI KUIN RESURSSIEN KAPASITEETTI (JOKA AJANHETKELLÄ)
function R_aux(ongoing_jobs::Vector{Int64}, timestep::Int64, resource_load_T::Dict{Any, Any}, K::Int64, T::Int64, I::Int64, freq::Int64)
    load_ongoing = Dict{Int64, Any}(key => zeros(1, K, T) for key in 1:I) #Initialize dictionary for loads. Key: job number, contains all jobs.
    #value: R[I,K,T], (or zero(I,K,T) if job is not ongoing). 
    
    schedule_timesteps = [t for t in 1:(timestep-1) if t % freq == 0 || t == 1]
    for step in schedule_timesteps
        arr = resource_load_T[step]
        arr_data = arr.data
        jobs_dict = (arr).lookup[1].data #job index and position-dictionary
        jobs_in_dict = collect(keys(jobs_dict))
        job_scheduled_now = intersect(ongoing_jobs, jobs_in_dict)
        for job in job_scheduled_now
            job_idx = jobs_dict[job] #index of given job
            load_ongoing[job] = arr_data[job_idx:job_idx,:,:] #Load of given job
        end
    end
    sorted_load = [load_ongoing[i] for i in 1:I]
    combined_load = cat(sorted_load...; dims=1)
    load_value = value.(combined_load)
    return load_value
end

#--------------------------------------------------------------------------------------------------------------------------------------------------------
#SOME PERFORMANCE METRICS, vielä kehitysasteella

##Numerical metrics:
#1. Käyttöaste (Utilization)
#2. Jonon pituus (Queue Length)
#3. Läpimenoaika (Throughput Time)
#4. Vapaa-aika (Idle Time)
#5. Läpimenokapasiteetti (Throughput Capacity)
#6. Odottamisen ja käsittelyn suhde (Waiting vs. Processing Time)
#7. Tehtävän viivästyminen (Task Delay)
#BONUS: jokin mittari kuorman ja kapasiteetin väliselle yhteydelle? esim. kuinka suuren osan ajasta resurssi on kuormitettuna yli 80% tms?

function utilization(load_profile_of_resource_k)
    #Utilization = amount of time resource is used / all time
    nonzero_load = count(x -> x != 0, load_profile_of_resource_k) #Number of timesteps when there is load on the resource
    utilization = nonzero_load / length(load_profile_of_resource_k)
    return utilization
end

function utilization_during_makespan(load_profile_of_resource_k)
    #Utilization = amount of time resource is used / all time
    #All time is not length of load_profile, but makespan of order
    nonzero_load = count(x -> x != 0, load_profile_of_resource_k) #Number of timesteps when there is load on the resource
    first_timestep = first(findall(x -> x != 0, load_profile_of_resource_k))[2]
    last_timestep = last(findall(x -> x != 0, load_profile_of_resource_k))[2]
    makespan = last_timestep - first_timestep + 1
    utilization = nonzero_load / makespan
    return utilization
end



function load_at_N_percent(load_profile_of_resource_k, capacity_k, N)
    #Load at N percent: number of timesteps when load is equal or over than N divided by number of all timesteps
    load_pct = load_profile_of_resource_k ./ capacity_k
    println(load_pct)
    load_N_pct = count(x -> x >= (N/100), load_pct)
    load_N = load_N_pct / length(load_profile_of_resource_k)
    return load_N
end
    
#Function which combines and prints numerical metrics describing how bottleneck each resource is.
function bottleneck_metrics(outputdata::OutputData)

end








