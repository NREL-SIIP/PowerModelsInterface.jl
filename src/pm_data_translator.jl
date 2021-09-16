
function get_pm_map(sys::PSY.System, template = default_template())
    pm_map = Dict{String, Any}()
    pm_map["branch"] = get_pm_map(sys, PSY.ACBranch, template.branches)
    pm_map["dcline"] =
        get_pm_map(sys, PSY.DCBranch, template.branches, length(pm_map["branch"]))
    pm_map["bus"] = get_pm_map(sys, PSY.Bus)
    pm_map["shunt"] = get_pm_map(sys, PSY.FixedAdmittance, template.devices)
    pm_map["load"] = get_pm_map(sys, PSY.StaticLoad, template.devices)

    thermal = get_pm_map(sys, PSY.ThermalGen, template.devices)
    renewable = get_pm_map(sys, PSY.ThermalGen, template.devices, length(thermal))
    hydro =
        get_pm_map(sys, PSY.HydroGen, template.devices, length(thermal) + length(renewable))
    pm_map["gen"] = merge(thermal, renewable, hydro)

    pm_map["storage"] = get_pm_map(sys, PSY.Storage, template.devices)
    return pm_map
end

function get_pm_map(
    sys::PSY.System,
    component_type::Type{T},
    devices_template::Dict{Symbol, Any},
    start_idx::Int = 0,
) where {T <: PSY.Component}
    devices = PSY.get_components(component_type, sys)

    PM_devices = Dict{String, component_type}()

    for (d, device_model) in devices_template
        !(device_model.component_type <: component_type) && continue
        start_idx += length(PM_devices)
        for (ix, device) in enumerate(devices)
            PM_devices["$(ix)"] = device
        end
    end
    return PM_devices
end

# dummy template to enable default PSY -> PM mapping but allow for more control in PSI
function default_template()
    template = (
        branches = Dict{Symbol, Any}(
            :ACBranch => (formulation = Any, component_type = PSY.ACBranch),
            :DCBranch => (formulation = Any, component_type = PSY.DCBranch),
        ),
        devices = Dict{Symbol, Any}(
            :thermal => (formulation = Any, component_type = PSY.ThermalGen),
            :renewable => (formulation = Any, component_type = PSY.RenewableGen),
            :load => (formulation = Any, component_type = PSY.StaticLoad),
            :storage => (formulation = Any, component_type = PSY.Storage),
            :shunt => (formulation = Any, component_type = PSY.FixedAdmittance),
        ),
        network = PM.AbstractPowerModel,
    )
    return template
end

function get_components_to_pm(
    sys::PSY.System,
    device_type::Type{T},
    devices_template::Dict{Symbol, Any},
    system_formulation::Type{S},
    start_idx = 0,
) where {T <: PSY.Component, S <: PM.AbstractPowerModel}
    devices = PSY.get_components(T, sys)
    PM_devices = Dict{String, Any}()

    for (d, device_model) in devices_template
        !(device_model.component_type <: device_type) && continue
        start_idx += length(PM_devices)
        for (ix, device) in enumerate(devices)
            PM_devices["$(ix)"] = get_component_to_pm(ix, device, Any)
        end
    end
    return PM_devices
end

const ACCEPTED_PM_DATA_KWARGS = [:name, :initial_time, :time_periods, :period]

"""
Creates a PowerModels data dictionary from a PowerSystems `System`. To populate time series
data in the resulting dataset, pass `initial_time` kwarg along with either `period` for a
single time period, or `time_periods` to create a multi-network dataset with multiple time periods

# Arguments
- `sys::System`: PowerSystems System
- `template::Any=default_template()`: Template to control data conversion

# Key word arguments
- `name::String`: system name
- `initial_time::DateTime`: `System` forecast initial time
- `time_periods::UnitRange{Int}=1:PSY.get_forecast_horizon(sys)`: indices for selecting forecast periods. Valid extent is `1:horizon`
- `period::Int=1`: index for selecting forecast period. Valid options
"""
function get_pm_data(sys::PSY.System, template = default_template(); kwargs...)
    PSY.set_units_base_system!(sys, "SYSTEM_BASE")

    ac_lines = get_components_to_pm(sys, PSY.ACBranch, template.branches, template.network)

    dc_lines = get_components_to_pm(
        sys,
        PSY.DCBranch,
        template.branches,
        template.network,
        #length(ac_lines),
    )

    pm_buses = get_components_to_pm(sys, PSY.Bus)
    pm_shunts =
        get_components_to_pm(sys, PSY.FixedAdmittance, template.devices, template.network)
    pm_gens = get_components_to_pm(sys, PSY.Generator, template.devices, template.network)
    pm_loads = get_components_to_pm(sys, PSY.StaticLoad, template.devices, template.network)
    pm_storages = get_components_to_pm(sys, PSY.Storage, template.devices, template.network)
    pm_areas = get_components_to_pm(sys, PSY.Area)

    pm_data_translation = Dict{String, Any}(
        "bus" => pm_buses,
        "branch" => ac_lines,
        "baseMVA" => PSY.get_base_power(sys),
        "per_unit" => true,
        "storage" => pm_storages,
        "dcline" => dc_lines,
        "gen" => pm_gens,
        "switch" => Dict{String, Any}(), #not present in PSY
        "shunt" => pm_shunts,
        "load" => pm_loads,
        "areas" => pm_areas,
        "name" => get(kwargs, :name, ""), # TODO: add name arg to function
        "source_type" => "PowerSystems.jl",
        "source_version" => PSY.DATA_FORMAT_VERSION,
    )

    initial_time = get(kwargs, :initial_time, nothing)
    if !isnothing(initial_time)
        if haskey(kwargs, :time_periods)
            time_periods = get(kwargs, :time_periods, 1:PSY.get_forecast_horizon(sys))
            @info "applying the $time_periods periods from the $initial_time forecast"
            pm_data_translation = apply_time_series(
                pm_data_translation,
                sys,
                kwargs[:initial_time],
                time_periods,
            )
        else
            period = get(kwargs, :period, 1)
            @info "applying the $period period from the $initial_time forecast"
            apply_time_period!(pm_data_translation, sys, kwargs[:initial_time], period)
        end
    end

    return pm_data_translation
end

function get_time_series_to_pm!(
    pm_data::Dict{String, Any},
    pm_category::String,
    pm_id::String,
    device::T,
    start_time::Dates.DateTime,
    time_periods::Union{UnitRange{Int}, Int},
) where {T <: PSY.Component}
    return # do nothing by default
end

function apply_time_series(
    pm_data::Dict{String, Any},
    sys::PSY.System,
    start_time::Dates.DateTime,
    time_periods::UnitRange{Int},
    template::Any = default_template(),
)
    pm_data =
        PM._IM.ismultinetwork(pm_data) ? pm_data :
        PM.replicate(pm_data, length(time_periods))
    @assert length(pm_data["nw"]) == length(time_periods)

    pm_map = get_pm_map(sys, template)

    for key in ["load", "gen"] #TODO: add shunt
        for (id, device) in pm_map[key]
            get_time_series_to_pm!(pm_data, key, id, device, start_time, time_periods)
        end
    end
    return pm_data
end

function apply_time_period!(
    pm_data::Dict{String, Any},
    sys::PSY.System,
    start_time::Dates.DateTime,
    time_period::Int,
    template::Any = default_template(),
)
    pm_map = get_pm_map(sys, template)

    for key in ["load", "gen"] #TODO: add shunt
        for (id, device) in pm_map[key]
            get_time_series_to_pm!(pm_data, key, id, device, start_time, time_period)
        end
    end
    return pm_data
end
