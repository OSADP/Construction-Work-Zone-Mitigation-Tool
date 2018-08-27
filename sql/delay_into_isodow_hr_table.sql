--this generates a table with TMC, DOW, hour, and estimated traversal time including delay for segments in the route that are potentially affected by delay

with
--route
r as (select time_start_of_segment, rgid, tmc, 
    --proportion of (length of rgid segment) / (length of the TMC segment)
    length_mi, length_mi / sum(length_mi) over (partition by tmc) as length_prop_tmc from routing.altroute_best1 order by rgid)
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
    from r left join dz using(tmc) order by rgid)
select * from dzr;





