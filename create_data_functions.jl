using DataFrames
using Distributions
using Graphs, Plots, GraphRecipes
using Random

#Samples random path based on discrete distribution given, and returns path index and used resources in that path.
function create_order_jobs(path_dictionary::Dict{Int64, Vector{Int64}}, path_distribution::Categorical{Float64, Vector{Float64}})
    #Order job generation:
    #1. Sample order path/recipe:
    order_path_idx = rand(path_distribution)
    #2. Get corresponding path
    order_path = path_dictionary[order_path_idx]
    order_resources = filter(x->x != 1, order_path) #Resources used in order. Length of this vector tells number of jobs aswell
    return (order_path_idx, order_resources)
end 

#Creates N orders, samples paths to them, and creates job indeces
#Returns dataframe, that will be modified (add work contents, durations etc. based on order id, job id and path id)
function create_orders(path_dictionary::Dict{Int64, Vector{Int64}}, N::Int64, path_distribution::Categorical{Float64, Vector{Float64}})
    order_indeces = Vector{Int64}()
    job_indeces = Vector{Int64}()
    path_indeces = Vector{Int64}()
    job_running_index = 1 #Starting index of current order
    for order in 1:N
        order_data = create_order_jobs(path_dictionary, path_distribution)
        path_idx = order_data[1]
        order_resources = order_data[2]
        number_of_jobs = length(order_resources)
        order_idx_rep = fill(order, number_of_jobs)
        path_idx_rep = fill(path_idx, number_of_jobs)
        job_idxs = collect(job_running_index:(job_running_index + number_of_jobs - 1))
        job_running_index = job_running_index + number_of_jobs
        #Append
        order_indeces = append!(order_indeces, order_idx_rep)
        job_indeces = append!(job_indeces, job_idxs)
        path_indeces = append!(path_indeces, path_idx_rep)
    end
    #To dataframe
    df = DataFrame(Order = order_indeces, Job = job_indeces, Path = path_indeces)
    return df
end

#Add arrival dates of orders to initial dataframe
function add_order_arrival(data::DataFrame, arrival_rate::Int64)
    data_w_arr = deepcopy(data)
    orders = unique(data.Order)
    number_of_orders = length(orders)
    arrivals = [1]
    arrivals = append!(arrivals, Int.(round.(cumsum(rand(Exponential(1/arrival_rate), number_of_orders - 1)) .+ 1)))
    @assert(length(arrivals) == number_of_orders)
    function get_arrival(order::Int64)
        return arrivals[order]
    end
    transform!(data_w_arr, :Order => ByRow(get_arrival) => :Arrival)
    return data_w_arr
end

#Add resource index for each job
function add_job_resource(data::DataFrame, path_dictionary::Dict{Int64, Vector{Int64}})
    data_job_resource = deepcopy(data)
    paths = unique(select(data_job_resource, :Order, :Path)).Path #Paths of each order
    job_resources = vcat([path_dictionary[path] for path in paths]...) #Resources used in paths
    job_resources_wo_aux = filter(x -> x != 1, job_resources) #Remove auxiliary resource 
    @assert(length(data_job_resource.Job) == length(job_resources_wo_aux))
    data_job_resource.Resource_idx = job_resources_wo_aux
    return data_job_resource
end

function truncated_gamma_realization(mu::Int64, CV::Float64, threshold_coefficient::Int64)
    #TODO
    threshold = mu * threshold_coefficient
    shape = 1 ./ CV.^2
    rate = 1 ./ (mu .* CV .^2)
    scale = 1/rate
    gamma_dist = Gamma(shape, scale)
    truncated_gamma_dist = truncated(gamma_dist, upper = threshold)
    realization = rand(truncated_gamma_dist)
    return realization
end

#Add work contents to dataframe
#Work content is truncated gamma distributed
#Example output:
# ...| job | Resource_idx | Resource_2 | .... | Resource_7 |
# ...|  1  |      2       |     WC_1   | .... |     0      |
# ...|  2  |      7       |      0     | .... |     WC_2   |
# .......
function add_work_contents(data::DataFrame, resource_mu::Vector{Int64}, resource_CV::Vector{Float64}, threshold_coefficient::Int64)
    data_wc = deepcopy(data)
    #Create columns for each resource 2:7
    for resource in 2:7
        data_wc[!, "Resource_$resource"] .= data_wc.Resource_idx .== resource
    end
    data_wc[!, 6:11] .+= 0 #Change booleans to 1/0
    res_idx = data_wc.Resource_idx
    function sample_wc(resource_id::Int64)
        mu = resource_mu[resource_id]
        CV = resource_CV[resource_id]
        realized_wc = truncated_gamma_realization(mu, CV, threshold_coefficient)
        return realized_wc
    end
    transform!(data_wc, :Resource_idx => ByRow(sample_wc) => :job_WC) 
    for j in 6:11
        data_wc[!, j] .= data_wc[!, j] .* data_wc.job_WC
    end
    return data_wc
end

#Add job durations to dataframe
#About job duration:
  #Job duration is calculated: dur = roundup(duration_coefficient * wc / working_time_in_day)
  #Except for dispatch centre, job there will always has duration of two days
  #working_time_in_day expresses how many hours a day resource is working
function add_durations(data::DataFrame, duration_coefficient::Vector{Int64}, working_hours::Vector{Int64})
    #Note: in resource 7 (dispatch centre) duration is always 2 (days)
    data_dur = deepcopy(data)
    function calculate_duration(WC::Float64, resource_idx::Int64)
        if resource_idx == 7
            duration = 2
        elseif resource_idx in collect(2:6)
            dur_coeff = duration_coefficient[resource_idx]
            work_hours = working_hours[resource_idx]
            duration = Int64(ceil(dur_coeff * WC / work_hours))
        else
            print("Wrong resource")
        end
        return duration
    end
    transform!(data_dur, :, [:job_WC, :Resource_idx] => ByRow(calculate_duration) => :Duration)
    return data_dur
end

#Add due dates of orders to dataframe
#Due date of order is calculated as follows:
    #1. Calculate minimum delivery time of order
    #2. Calculate slack: slack_coefficient * minimum_delivery_time
    #3. Due date: Arrival time + minimum delivery time + slack
function add_due_dates(data::DataFrame; slack_coefficient::Float64 = 0.5)
    data_duedate = deepcopy(data)
    data_duedate = transform(groupby(data_duedate, :Order), :Duration => sum => :MinDelivery)
    data_duedate = transform(data_duedate, :MinDelivery => (a -> a * slack_coefficient) => :Slack)
    data_duedate = transform(data_duedate, [:Arrival, :MinDelivery, :Slack] => ByRow((a,b,c) -> Int64(ceil(a + b + c))) => :Duedate)
    return data_duedate
end

struct DataParameters
    number_of_orders::Int64
    arrival_rate::Int64
    resource_mean::Vector{Int64}
    resource_CV::Vector{Float64}
    threshold_coefficient::Int64
    duration_coefficient::Vector{Int64}
    working_hours_day::Vector{Int64}
    slack_coefficient::Float64
    seed::Int64

    function DataParameters(number_of_orders, arrival_rate, resource_mean, resource_CV, threshold_coefficient, duration_coefficient, 
                            working_hours_day, slack_coefficient, seed)
        #Check lengths
        length(resource_mean) == 7 || throw(ArgumentError("resource_mean length should be 7"))
        length(resource_CV) == 7 || throw(ArgumentError("resource_CV length should be 7"))
        length(duration_coefficient) == 7 || throw(ArgumentError("duration_coefficient length should be 7"))
        length(working_hours_day) == 7 || throw(ArgumentError("working_hours_day length should be 7"))

        new(number_of_orders, arrival_rate, resource_mean, resource_CV, threshold_coefficient, duration_coefficient, 
                            working_hours_day, slack_coefficient, seed)        
    end
end

function create_data(params::DataParameters)
    Random.seed!(params.seed)
    #Step 1: Create initial dataframe, which contains orders with sampled paths
    dist = Categorical(path_probs_vec) 
    n_orders = params.number_of_orders
    start_df = create_orders(path_dict, n_orders, dist) 
    #Step 2: Add arrival times for each order
    arrival_rate = params.arrival_rate
    df_arrival = add_order_arrival(start_df, arrival_rate)
    #Step 3: Add resource for each job, based on order path and job position in order
    df_resource = add_job_resource(df_arrival, path_dict)
    #Step 4: Add job work contents
    res_mean = params.resource_mean
    res_CV = params.resource_CV
    thres_coeff = params.threshold_coefficient
    df_workcontent = add_work_contents(df_resource, res_mean, res_CV, thres_coeff)
    #Step 5: Add job durations
    duration_coefficient = params.duration_coefficient
    working_time_in_day = params.working_hours_day
    df_durations = add_durations(df_workcontent, duration_coefficient, working_time_in_day)
    #Step 6: Add due dates
    slack = params.slack_coefficient
    df_final = add_due_dates(df_durations, slack_coefficient = slack)
    return df_final
end


