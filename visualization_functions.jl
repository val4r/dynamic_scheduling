using DataFrames
using VegaLite
using StatsPlots

#funktio joka palauttaa Gantt-kuvaajan. Tarkoitettu käytettäväksi staattisen mallin kanssa
#Input:
    #mallin parametrit ja mallista c-muuttujan lopputulos.
#Output
    #plot
function create_gantt_chart(c::Matrix{VariableRef}, T::Int64, P::Vector{Int64}, I::Int64, O::Vector{Int64})
    Tspan = [i for i in 1:T]
    Finish_times = value.(c)*Tspan
    Start_times = Finish_times .- P
    jobs = [i for i in 1:I]
    orders = O

    df = DataFrame(job = jobs, start = Start_times, stop = Finish_times, order = orders)
    df |> @vlplot(
                :bar,
                y="job:n",
                x=:start,
                x2=:stop,
                color={"field" = :order, "type" = "nominal"}
              )
end

#
function create_dynamic_gantt_chart(start_times::Vector{Int64}, finish_times::Vector{Int64}, I::Int64, O::Vector{Int64}, t::Int64)
    jobs = [i for i in 1:I]
    orders = O

    df = DataFrame(job = jobs, start = start_times, stop = finish_times, order = orders)
    
    line_data = [(x=P[1], y=1), (x=P[1], y=4)]
    
    df |> 
    @vlplot() + 
    @vlplot(
            :bar,
            y="job:n",
            x=:start,
            x2=:stop,
            color={"field" = :order, "type" = "nominal"}
            ) +
    @vlplot(mark={:rule, strokeDash=[2,2], size=2}, x={datum=t})
    
end



function create_resource_load(R::Array{VariableRef}, k::Int64)
    resource_load = value.(R[:,k,:]) #työn i ajanhetkellä t tuottama kuorma resurssille k
    ticklabel = [t for t in 1:T]
    orderlabel = transpose([o for o in 1:(I/4)]) #HUOM! TÄMÄ ON KOVAKOODATTU, MUUTA JOS TILAUKSEN TÖIDEN MÄÄRÄ MUU KUIN 4
    
    start_row = k
    step = 4 #HUOM! TÄMÄ ON KOVAKOODATTU, MUUTA JOS TILAUKSEN TÖIDEN MÄÄRÄ MUU KUIN 4
    rows = start_row:step:size(resource_load, 1)

    R_resource_k = resource_load[rows, :]

    groupedbar(transpose(R_resource_k),
            bar_position = :stack,
            bar_width=0.7,
            xticks=(1:T, ticklabel),
            label=orderlabel,
            color = ["#19334c" "#cc1919" "#19cc19" "#cccc19" "#8032cc" "#33cccc" "#cc8033" "#808080" "#cc9999" "#1cbb4d"])
end
