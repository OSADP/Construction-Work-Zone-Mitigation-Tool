 --input is a route, with either the time_start or time_end as one input
 --start at the first record, get the time stamp, either start or arrive
    --get isodow, hour from the time stamp
    --get estimated speed from related record in isodow/hr/tmc speed table (match on TMC, iso_dow, hr)
    --get estimated traversal time as (length_mi / speed) from the related record
    --add delay_hours_rgid to the estimated traversal time as estimated traversal time with delay. Usually the delay is 0.
    --if _forward
        --add time_start + (estimated traversal time with delay) = time_end_of_segment
    --else
        --time_end - estimated_travel_time_with_delay = time_start
    --time_start_of segment = time_end_of_segment
    --LOOP

--need a return type for records that are output iteratively
drop type if exists route_timestep_return_type cascade;
create type route_timestep_return_type as (
    tmc text
    , rgid bigint
    , roadname text
    , length_mi float
    , time_start_of_segment timestamptz
    , time_end_of_segment timestamptz
    , hours float
    , geom geometry
);  

drop function if exists npmrds_route_timestep_dow_hr_delay(
      _route_table text
    , _route_geom_field text
    , _init_time text   --start or end time
    , _speed_table text --npmrds.speed_truck_dow_hr
    , _use_delay bool   --use delay or not
    , _forward bool);    --default is to start at the first rgid and move downward, adding, otherwise start at last, subtracting
create function npmrds_route_timestep_dow_hr_delay(
      _route_table text
    , _route_geom_field text
    , _init_time text   --start or end time
    , _speed_table text --npmrds.speed_truck_dow_hr
    , _use_delay bool default true
    , _forward bool default true)   --default is to start at the first rgid and move downward, adding, otherwise start at last, subtracting

returns setof route_timestep_return_type as
$$
#variable_conflict use_column

DECLARE
    _isorec record; -- the related record from the speed table    
    _routerec record;   --the record from the route
    _routesql text;     --sql to get the route 
    _sort_direction text;       --asc or desc for rgid sorting
    _time0 timestamptz;         --time stamp for proceeding with calculation (either last arrival time if timing based on arrive or first start)
    _time1 timestamptz;         --time stamp corresponding to addition or subtraction of traverse
    _iso_dow integer;           --isodow (1 = Monday)
    _hr integer;                --hour of day
    _delay_start timestamptz;   --time when a delay starts
    _delay_end timestamptz;     --time when a delay ends
    _tmc text;                  --segment's TMC code
    _speedsql text;             --SQL to select related speed record
    _traverse_dur_hours float;  --time to traverse the segment
    _speed float;               --speed from the speeds table
    _length_mi float;           --length from the route table
    _delay_hours float;         --additional hours of delay from the processed route table
    _traverse_dur_hours_delay float;    --traversal time with added delay
    _outrec route_timestep_return_type; --what comes out of the time stepper
    _rgid bigint;                  --unique route-ordered record identifier
    _roadname text;
    _geom geometry;
    
begin

--forward or backward?
if _forward then
    _sort_direction := 'asc';
else
    _sort_direction := 'desc';
end if;

--isodow and hr from input time stamp (first iteration)
execute 'select extract(isodow from '''|| _init_time ||'''::timestamptz)::int' into _iso_dow;
execute 'select extract(hour from '''|| _init_time ||'''::timestamptz)::int' into _hr;

--sql to select records from the route
if _use_delay 
then
    _routesql := 
    'with
    --route
    r as (select rgid, tmc, roadname
        --proportion of (length of rgid segment) / (length of the TMC segment)
        , length_mi
        , length_mi / sum(length_mi) over (partition by tmc) as length_prop_tmc 
        , '|| _route_geom_field ||' as geom
        from routing.'|| _route_table ||' order by rgid)
    --work zone
    , z as (select * from routing.construction_zone)
    --delay as interval
    , d as (select * from routing.constructiondelay)
    --delay across zone
    , dz as (select zone_num, tmc, delay_start, delay_end, delay_minutes as delay_minutes_tmc from d join z using(zone_num))
    --zone delay on route records
    , dzr as (select *, 
        --apportions the delay over all segments in the work zone, (segment length) / (total length of work zone)
        coalesce(delay_minutes_tmc * length_mi / sum(length_mi) over (partition by zone_num) / 60, 0) as delay_hours_rgid 
        from r left join dz using(tmc))
    select * from dzr order by rgid '|| _sort_direction ||';';
else
    _routesql := 
    'with
    --route
    r as (select rgid, tmc, roadname
        --proportion of (length of rgid segment) / (length of the TMC segment)
        , length_mi
        , length_mi / sum(length_mi) over (partition by tmc) as length_prop_tmc 
        , '|| _route_geom_field ||' as geom
        , null::int as zone_num, null::timestamptz as delay_start, null::timestamptz as delay_end, null::int as delay_minutes_tmc, null::float as delay_hours_rgid
        from routing.'|| _route_table ||' order by rgid)
    select * from r order by rgid '|| _sort_direction ||';';
end if;

raise notice 'route sql: %', _routesql;

--first time is a runtime parameter
_time0 := _init_time::timestamptz;

--loop over each record in the route
for _routerec in execute _routesql loop
    --raise notice '%', _routerec;

    --stuff from the route table
    --delay start and end
    _delay_start := _routerec.delay_start;
    _delay_end := _routerec.delay_end;
    _tmc := _routerec.tmc;
    _rgid := _routerec.rgid;
    _length_mi := _routerec.length_mi;
    _roadname := _routerec.roadname;
    _geom := _routerec.geom;

    --use delay?
    if _use_delay then
        _delay_hours := _routerec.delay_hours_rgid;
    else
        _delay_hours := 0;
    end if;
    
    --get the related speed
    _speedsql := 'select tmc, speed, iso_dow::int, hr::int from '|| _speed_table ||' where tmc = '''|| _tmc ||''' and iso_dow = '|| _iso_dow ||' and hr = '|| _hr ||'';
    execute _speedsql into _isorec;
    _tmc := _isorec.tmc;
    _speed := _isorec.speed;
    --raise notice '%', _tmc;

    --calculate estimated traversal time
    _traverse_dur_hours := _length_mi / _speed;
    --and traversal time with delay
    _traverse_dur_hours_delay := _traverse_dur_hours + _delay_hours;

    --estimate time at end (or start) of segment
    if _forward then
        _time1 := _time0 + interval '1 hour' * _traverse_dur_hours_delay;
        --SELECT _tmc, _rgid, _roadname, _iso_dow, _hr, _time0, _time1 into _outrec;
        SELECT _tmc, _rgid, _roadname, _length_mi, _time0, _time1, _traverse_dur_hours_delay, _geom into _outrec;
    else
        _time1 := _time0 - interval '1 hour' * _traverse_dur_hours_delay;
        --SELECT _tmc, _rgid, _roadname, _iso_dow, _hr, _time1, _time0 into _outrec;
        SELECT _tmc, _rgid, _roadname, _length_mi, _time1, _time0, _traverse_dur_hours_delay, _geom into _outrec;
    end if;

    --new time_start as time_end
    _time0 := _time1;    

    return next _outrec;
   
end loop;

return;

end;

$$ language 'plpgsql';

--an example
-- select 
-- tmc, rgid, roadname, length_mi, time_start_of_segment, time_end_of_segment, hours, geom as the_geom_32614
-- from npmrds_route_timestep_dow_hr_delay(_route_table := 'bestroute', _route_geom_field := 'the_geom_32614', _init_time := '2017-04-19 12:00', _speed_table := 'npmrds.speed_truck_dow_hr', _forward := true) order by rgid;

select
tmc, rgid, roadname, length_mi, time_start_of_segment, time_end_of_segment, hours, geom as the_geom_32614
from npmrds_route_timestep_dow_hr_delay(_route_table := 'baseroute', _route_geom_field := 'the_geom_32614', _init_time := '2017-04-19 17:00', _speed_table := 'npmrds.speed_truck_dow_hr', _forward := false, _use_delay := false) order by rgid;

