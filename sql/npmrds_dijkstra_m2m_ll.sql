-- a function to generate the best route
-- creates a named table
--relies on pgr_dijkstra in pgRouting

drop function if exists npmrds_dijkstra_m2m_ll(      
      _out_tablename text   --tablename to create in routing
    , _time_start text --time to start
    , _origin_lat float --origin latitude
    , _origin_lon float --origin longitude
    , _dest_lat float   --origin latitude
    , _dest_lon float   --origin longitude
    , _srid int         --EPSG code for projected data, e.g., 32614 = UTM 12 N
    , _edge_tablename text --default 'npmrds.roads_topo' -- the name of the table containing network data, assume has columns id, source, target.      e.g., npmrds.texas_noded
    , _edge_geomfield text --default 'the_geom_32614' -- column name containing network geometry.       e.g., the_geom_32614
    , _edge_costfield text --default 'cost_truck' -- column representing costs
    , _edge_reversecostfield text --default 'reverse_cost_truck' -- column representing reverse costs
    , _edge_speedfield text --default 'speed_truck' -- column containing speed
    , _edge_vertex_tablename text --default 'npmrds.roads_topo_vertices_pgr' -- the name of the table containing network nodes data.        e.g., npmrds.texas_noded_vertices_pgr
    , _edge_vertex_geomfield text --default 'the_geom' -- column name containing vertex geometry
    , _mytol int --default 10000
    , _n_verts int --default 5
    );
--_odtablename: {npmrds.odregional, npmrds.odnational)
--_mytol is the tolerance for looking for vertices around an OD pair's points.
--_n_verts is the number of vertices close to the O and D form many-to-many
create function npmrds_dijkstra_m2m_ll(
      _out_tablename text   --tablename to create in routing
    , _time_start text --time to start
    , _origin_lat float --origin latitude
    , _origin_lon float --origin longitude
    , _dest_lat float   --origin latitude
    , _dest_lon float   --origin longitude
    , _srid int         --EPSG code for projected data, e.g., 32614 = UTM 12 N
    , _edge_tablename text default 'npmrds.roads_topo' -- the name of the table containing network data, assume has columns id, source, target.      e.g., npmrds.texas_noded
    , _edge_geomfield text default 'the_geom_32614' -- column name containing network geometry.       e.g., the_geom_32614
    , _edge_costfield text default 'cost_truck' -- column representing costs
    , _edge_reversecostfield text default 'reverse_cost_truck' -- column representing reverse costs
    , _edge_speedfield text default 'speed_truck' -- column containing speed
    , _edge_vertex_tablename text default 'npmrds.roads_topo_vertices_pgr' -- the name of the table containing network nodes data.        e.g., npmrds.texas_noded_vertices_pgr
    , _edge_vertex_geomfield text default 'the_geom' -- column name containing vertex geometry
    , _mytol int default 10000
    , _n_verts int default 5)
returns void as
$$
#variable_conflict use_column

DECLARE
    _mysql text; -- the SQL string    

begin

--if there was no start time entered,use NOW()
if _time_start is null then
    _time_start = now();
end if;

_mysql := '
drop table if exists routing.'|| _out_tablename ||';
create table routing.'|| _out_tablename ||' as
with
--start time
tm as (select '''|| _time_start ||'''::timestamptz as time_start)
--tm as (select quote_literal(_time_start)::timestamptz as time_start)
--tolerance
, t as (select '|| _mytol ||' as tol)
--edges
, e as (select *, id as edge, '|| _edge_geomfield ||' as geom_e, '|| _edge_costfield ||', '|| _edge_reversecostfield ||' from '|| _edge_tablename ||')
--vertices
, v as (select id as v_id, '|| _edge_vertex_geomfield ||' as geom_v from '|| _edge_vertex_tablename ||')
--origin, destination
, o as (select st_transform(st_geomfromewkt(''SRID=4326;POINT('|| _origin_lon ||' '|| _origin_lat ||')''), '|| _srid ||') as geom_o)
, d as (select st_transform(st_geomfromewkt(''SRID=4326;POINT('|| _dest_lon ||' '|| _dest_lat ||')''), '|| _srid ||') as geom_d)
--vertices near origin
, vo as (select v.v_id, geom_v from v, o, t where st_dwithin(geom_v, geom_o, t.tol))
--vertices near destination
, vd as (select v.v_id, geom_v, st_distance(geom_v, geom_d) from v, d, t where st_dwithin(geom_v, geom_d, t.tol))
--vertex closest to origin
, vco as (select * from vo, o order by geom_v <-> geom_o limit '|| _n_verts ||')
--vertex closest to destination
, vcd as (select * from vd, d order by geom_v <-> geom_d limit '|| _n_verts ||')
--route
, nd as (select pgr_dijkstra(''SELECT id, source, target, '|| _edge_costfield ||' as cost, '|| _edge_reversecostfield ||' as reversecost FROM '|| _edge_tablename  ||' where '|| _edge_costfield ||' is not null'', array[vco.v_id], array[vcd.v_id], true) as c from vco, vcd)
, n0 as (select (c).* from nd)
, n as (select start_vid  ||''_''|| end_vid as sevid, * from n0)
--summed hours for shortest path
, hrs as (select sevid, sum(cost) from n group by sevid order by sum(cost) asc limit 1)
--records from shortest path
, nh as (select * from n where sevid = (select sevid from hrs))
--join to edges
, nj as (select nh.*, e.'|| _edge_geomfield ||', e.'|| _edge_speedfield ||', roadname::text, tmc::text, (st_length('|| _edge_geomfield ||') / 1609.34)::float as length_mi from nh left join e using(edge), tm where '|| _edge_geomfield ||' is not null order by path_seq)
--, tx as (select *, time_start + interval ''1 hour'' * agg_cost as time_start_of_segment, time_start + interval ''1 hour'' * (cost + agg_cost) as time_end_of_segment from nj, tm)
, f as (select split_part(sevid, ''_'', 1)::int as start_vertex, split_part(sevid, ''_'', 2)::int as end_vertex, -1 as via_vertex, row_number() over() as rgid, '|| _origin_lat ||'::float as origin_lat, '|| _origin_lon ||'::float as origin_lon, '|| _dest_lat ||'::float as dest_lat, '|| _dest_lon ||'::float as dest_lon,
roadname, tmc, '|| _edge_speedfield ||', cost as hours, length_mi, '|| _edge_geomfield ||'::geometry(LineString, '|| _srid ||') from nj)
select * from f;
create index idx_'|| _out_tablename ||' on routing.'|| _out_tablename ||' using btree(tmc);
'
;

--raise notice '%', _mysql;

execute _mysql;
return;

end;

$$ language 'plpgsql';

-- -- example 1
-- drop table if exists npmrds.austin_sanantonio;
-- create table npmrds.austin_sanantonio as 
-- with
-- r as (select * from npmrds_dijkstra_m2m(_time_start := '2017-04-01 12:00:00-07', _odpairid:= 3))
-- , t as (select distinct tmc, roadname from npmrds.roads) 
-- , j1 as (select t.roadname, r.* from r join t using(tmc) order by time_start_of_segment)
-- , j2 as (select row_number() over() as seq, * from j1)
-- , j3 as (select row_number() OVER(ORDER BY seq ASC) - row_number() OVER(PARTITION BY roadname ORDER BY seq ASC) AS grp, * from j2 order by seq)
-- , j4 as (select min(seq) over(partition by grp) as seq2, * from j3)
-- , j5 as (select seq2, roadname, date_trunc('second', min(time_start_of_segment)) as time_start_of_segment, date_trunc('second', max(time_end_of_segment)) as time_end_of_segment, round((sum(hours::numeric))*60, 1) as minutes, round(sum(length_mi), 1) as length_mi, st_linemerge(st_union(geom))::geometry(linestring, 32614) as geom from j4 group by seq2, roadname order by seq2)
-- , j6 as (select row_number() over() as gid, * from j5)
-- select * from j6;
-- 
-- --example 2
-- drop table if exists npmrds.dallas_waco;
-- create table npmrds.wallas_waco as 
-- with
-- r as (select * from npmrds_dijkstra_m2m(_time_start := '2017-04-01 12:00:00-07', _odpairid:= 8))
-- , t as (select distinct tmc, roadname from npmrds.roads) 
-- , j1 as (select t.roadname, r.* from r join t using(tmc) order by time_start_of_segment)
-- , j2 as (select row_number() over() as seq, * from j1)
-- , j3 as (select row_number() OVER(ORDER BY seq ASC) - row_number() OVER(PARTITION BY roadname ORDER BY seq ASC) AS grp, * from j2 order by seq)
-- , j4 as (select min(seq) over(partition by grp) as seq2, * from j3)
-- , j5 as (select seq2, roadname, date_trunc('second', min(time_start_of_segment)) as time_start_of_segment, date_trunc('second', max(time_end_of_segment)) as time_end_of_segment, round((sum(hours::numeric))*60, 1) as minutes, round(sum(length_mi), 1) as length_mi, st_linemerge(st_union(geom))::geometry(linestring, 32614) as geom from j4 group by seq2, roadname order by seq2)
-- , j6 as (select row_number() over() as gid, * from j5)
-- select * from j6;


--select * from npmrds_dijkstra_m2m_ll('2018-04-23 12:00', 30.2888, -97.62944, 29.456373, -98.402132, 32614);

--select * from npmrds_dijkstra_m2m_ll('2018-04-23 12:00', 31.132861, -97.359295, 30.009145, -97.858829, 32614, 'npmrds.roads', 'the_geom_32614', 'npmrds.roads_vertices_pgr', 'the_geom_32614');

--select * from npmrds_dijkstra_m2m_ll('2018-04-23 12:00', 31.132046, -97.360024, 32.645262, -96.865897, 32614, 'npmrds.roads_topo', 'the_geom_32614', 'npmrds.roads_topo_vertices_pgr', 'the_geom');

--select * from npmrds_dijkstra_m2m_ll('bestroute', '2017-04-19 12:00', 31.807419, -97.099599, 29.456373, -98.402132, 32614, 'npmrds.roads_topo', 'the_geom_32614', 'cost_truck', 'reverse_cost_truck', 'speed_truck', 'npmrds.roads_topo_vertices_pgr', 'the_geom');

select * from npmrds_dijkstra_m2m_ll(
      _out_tablename := 'baseroute'
    , _time_start := '2017-04-19 12:00'
    , _origin_lat := 31.807419
    , _origin_lon := -97.099599
    , _dest_lat := 29.456373
    , _dest_lon := -98.402132
    , _srid := 32614
    , _edge_tablename := 'npmrds.roads_topo'
    , _edge_geomfield := 'the_geom_32614'
    , _edge_costfield := 'cost_truck'
    , _edge_reversecostfield := 'reverse_cost_truck'
    , _edge_speedfield := 'speed_truck'
    , _edge_vertex_tablename := 'npmrds.roads_topo_vertices_pgr'
    , _edge_vertex_geomfield := 'the_geom');

select * from routing.baseroute;

