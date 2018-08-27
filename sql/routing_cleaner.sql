--clean up routing

drop function if exists routing_cleaner();
create function routing_cleaner()
returns void as
$$

declare 
    _dropsql text;
    _dropsql2 text;
    _droprec record;

begin
    
--#######################################
--drop any existing alternate routes
_dropsql := 'select table_name from information_schema.tables where table_schema ~ ''routing''';
for _droprec in execute _dropsql loop
    _dropsql2 := 'drop table routing.'|| _droprec.table_name ||'';
    execute _dropsql2;
    raise notice 'dropping %', _droprec.table_name;
end loop;

end;

$$ language 'plpgsql';

select routing_cleaner();

select table_name from information_schema.tables where table_schema ~ 'routing' ;--and table_name ~ '^altroute';
