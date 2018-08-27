--master function for generating routes

drop function if exists npmrds_run_wrapper(
    _constructiondelayfile text
    , _constructionzonefile text
    , _viavertexfile text
    , _edge_tablename text
    , _edge_geomfield text
    , _speed_tablename text
    , _srid int
    , _edge_speedfield text
    , _edge_costfield text
    , _edge_reversecostfield TEXT
    , _edge_vertex_tablename text
    , _edge_vertex_geomfield text
    , _mytol integer
    , _n_verts integer
    , _time_init text
    , _origin_lat float
    , _origin_lon float
    , _dest_lat float
    , _dest_lon float
    , _forward bool);
create function npmrds_run_wrapper(
    _constructiondelayfile text
    , _constructionzonefile text
    , _viavertexfile text
    , _edge_tablename text
    , _edge_geomfield text
    , _speed_tablename text
    , _srid int
    , _edge_speedfield text
    , _edge_costfield text
    , _edge_reversecostfield TEXT
    , _edge_vertex_tablename text
    , _edge_vertex_geomfield text
    , _mytol integer
    , _n_verts integer
    , _time_init text
    , _origin_lat float
    , _origin_lon float
    , _dest_lat float
    , _dest_lon float
    , _forward bool default true)
returns void as
$$

declare 
    _sql text;
    _timestep_sql text;

begin

_sql := '
--############################### CLEANING
--start by house cleaning
select routing_cleaner();

--############################### DELAYS
--drop delay if exists
drop table if exists routing.constructiondelay;
--create table
create table routing.constructiondelay(zone_num int, delay_start timestamptz, delay_end timestamptz, delay_minutes int);
--copy data into table
copy routing.constructiondelay from '''|| _constructiondelayfile ||''' with csv header;

--############################### WORK ZONES
--drop zones if exists
drop table if exists routing.construction_zone;
--create table
create table routing.construction_zone(zone_num int, tmc text);
--copy data into table
copy routing.construction_zone from '''|| _constructionzonefile ||''' with csv header;

--############################### ISO_DOW, HR, TMC format from delays to make a new version of the ISODOW table


--############################### VIA POINTS
drop table if exists routing.via_vertex;
create table routing.via_vertex (id integer);
copy routing.via_vertex from '''|| _viavertexfile ||''' with csv header;

--#######################
--run routes to establish O/D, segments
--no delay, base route, to establish origin, destination, and sequence of TMCs
select * from npmrds_dijkstra_m2m_ll(
    _out_tablename := ''baseroute''
    , _time_start := '''|| _time_init ||'''
    , _origin_lat := '|| _origin_lat ||'    
    , _origin_lon := '|| _origin_lon ||'
    , _dest_lat := '|| _dest_lat ||'
    , _dest_lon := '|| _dest_lon ||'
    , _srid := '|| _srid ||'
    , _edge_tablename := '''|| _edge_tablename ||'''
    , _edge_geomfield := '''|| _edge_geomfield ||'''
    , _edge_costfield := '''|| _edge_costfield ||'''
    , _edge_reversecostfield := '''|| _edge_reversecostfield ||'''
    , _edge_speedfield := '''|| _edge_speedfield ||'''
    , _edge_vertex_tablename := '''|| _edge_vertex_tablename ||'''
    , _edge_vertex_geomfield := '''|| _edge_vertex_geomfield ||'''
    , _mytol := '|| _mytol ||'
    , _n_verts := '|| _n_verts ||');

--"via"
--no delay
select * from npmrds_dijkstra_ll_via(
    _out_tablename := ''altbase_''
    , _route_tablename := ''routing.baseroute''
    , _edge_tablename := '''|| _edge_tablename ||''');

--####################### TIME STEPPING
--bestroute
select 
tmc, rgid, roadname, length_mi, time_start_of_segment, time_end_of_segment, hours, geom as '|| _edge_geomfield ||'
into routing.bestroute from 
npmrds_route_timestep_dow_hr_delay(
    _route_table := ''baseroute''
    , _route_geom_field := '''|| _edge_geomfield ||'''
    , _init_time := '''|| _time_init ||'''
    , _speed_table := '''|| _speed_tablename ||'''
    , _forward := '|| _forward ||'
    , _use_delay := false
    ) order by rgid;

--bestroute with delay
select 
tmc, rgid, roadname, length_mi, time_start_of_segment, time_end_of_segment, hours, geom as '|| _edge_geomfield ||'
into routing.bestroute_delay from 
npmrds_route_timestep_dow_hr_delay(
    _route_table := ''baseroute''
    , _route_geom_field := '''|| _edge_geomfield ||'''
    , _init_time := '''|| _time_init ||'''
    , _speed_table := '''|| _speed_tablename ||'''
    , _forward := '|| _forward ||'
    , _use_delay := true
    ) order by rgid;

--alternative 1
--no delay
select 
tmc, rgid, roadname, length_mi, time_start_of_segment, time_end_of_segment, hours, geom as '|| _edge_geomfield ||'
into routing.altroute_best1
from npmrds_route_timestep_dow_hr_delay(
    _route_table := ''altbase_best1''
    , _route_geom_field := '''|| _edge_geomfield ||'''
    , _init_time := '''|| _time_init ||'''
    , _speed_table := '''|| _speed_tablename ||'''
    , _forward := '|| _forward ||'
    , _use_delay := false
    ) order by rgid;

    select 
    
--with delay
tmc, rgid, roadname, length_mi, time_start_of_segment, time_end_of_segment, hours, geom as '|| _edge_geomfield ||'
into routing.altroute_best1_delay 
from npmrds_route_timestep_dow_hr_delay(
    _route_table := ''altbase_best1''
    , _route_geom_field := '''|| _edge_geomfield ||'''
    , _init_time := '''|| _time_init ||'''
    , _speed_table := '''|| _speed_tablename ||'''
    , _forward := '|| _forward ||'
    , _use_delay := true
    ) order by rgid;

--alternative 2
--no delay
select 
tmc, rgid, roadname, length_mi, time_start_of_segment, time_end_of_segment, hours, geom as '|| _edge_geomfield ||'
into routing.altroute_best2
from npmrds_route_timestep_dow_hr_delay(
    _route_table := ''altbase_best2''
    , _route_geom_field := '''|| _edge_geomfield ||'''
    , _init_time := '''|| _time_init ||'''
    , _speed_table := '''|| _speed_tablename ||'''
    , _forward := '|| _forward ||'
    , _use_delay := false
    ) order by rgid;

--with delay
select 
tmc, rgid, roadname, length_mi, time_start_of_segment, time_end_of_segment, hours, geom as '|| _edge_geomfield ||'
into routing.altroute_best2_delay
from npmrds_route_timestep_dow_hr_delay(
    _route_table := ''altbase_best2''
    , _route_geom_field := '''|| _edge_geomfield ||'''
    , _init_time := '''|| _time_init ||'''
    , _speed_table := '''|| _speed_tablename ||'''
    , _forward := '|| _forward ||'
    , _use_delay := true
    ) order by rgid;

    
--driving data
select * from driving_directions(''routing.bestroute'','''|| _edge_geomfield ||''');
select * from driving_directions(''routing.bestroute_delay'','''|| _edge_geomfield ||''');

select * from driving_directions(''routing.altroute_best1'','''|| _edge_geomfield ||''');
select * from driving_directions(''routing.altroute_best1_delay'','''|| _edge_geomfield ||''');

select * from driving_directions(''routing.altroute_best2'','''|| _edge_geomfield ||''');
select * from driving_directions(''routing.altroute_best2_delay'','''|| _edge_geomfield ||''');
';

raise notice '%', _sql;

execute _sql;

raise notice 'complete.';

end;

$$ language 'plpgsql';

--example
select * from npmrds_run_wrapper(
    _constructiondelayfile := '/projects/fratis/npmrds/construction_delays.csv'
    , _constructionzonefile := '/projects/fratis/npmrds/construction_zones.csv'
    , _viavertexfile := '/projects/fratis/npmrds/via_ids.csv'
    , _edge_tablename := 'npmrds.roads_topo'
    , _edge_geomfield := 'the_geom_32614'
    , _speed_tablename:= 'npmrds.speed_truck_dow_hr'
    , _srid := 32614
    , _edge_speedfield := 'speed_truck'
    , _edge_costfield := 'cost_truck'
    , _edge_reversecostfield := 'reverse_cost_truck'
    , _edge_vertex_tablename := 'npmrds.roads_topo_vertices_pgr'
    , _edge_vertex_geomfield := 'the_geom'
    , _mytol := 10000
    , _n_verts := 10
    , _time_init := '2017-04-19 17:00'
    , _origin_lat := 32.66842
    , _origin_lon := -97.32203
    , _dest_lat := 29.456373
    , _dest_lon := -98.402132
    , _forward := false);

