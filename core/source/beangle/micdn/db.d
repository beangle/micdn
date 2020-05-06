module beangle.micdn.db;

import vibe.db.postgresql;
import std.datetime.systime;
import beangle.micdn.config;

class MetaDao{

    PostgresClient client;
    string tableName;

    this(string[string] props){
        import std.format;
        import std.conv;
        auto url = format( "host=%s dbname=%s user=%s password=%s",props["serverName"],props["databaseName"],props["user"],props["password"]);
        auto maximumPoolSize= props.get( "maximumPoolSize","10").to!ushort;
        tableName= props["tableName"];
        client = new PostgresClient( url, maximumPoolSize);
    }

    void remove(Profile profile,string path){
        client.pickConnection(
        (scope conn) {
            QueryParams query;
            query.sqlCommand = "delete from "~tableName~" where profile_id=$1 and path=$2";
            import std.conv;
            query.argsVariadic( profile.id,path);
            conn.execParams( query);
        }
        );
    }

    public bool create(Profile profile,BlobMeta m){
        bool success=false;
        client.pickConnection(
        (scope conn) {
            QueryParams query;
            query.sqlCommand = "insert into "~tableName
            ~" (id,owner,name,size,sha,media_type,profile_id,path,updated_at) values(datetime_id(),$1,$2,$3,$4,$5,$6,$7,$8)";
            import std.conv;
            query.argsVariadic( m.owner,m.name,m.size.to!long,m.sha,m.mediaType,m.profileId,m.path,m.updatedAt);
            try{
                conn.execParams( query);
                success= true;
            }catch(Exception ){
                success= false;
            }
        }
        );
        return success;
    }
}

unittest{
    string[string] props;
    props["serverName"]="localhost";
    props["databaseName"]="platform";
    props["user"]="openurp";
    props["tableName"]="blobs.blob_metas";
    //props["password"]="openurp";
    if ("password" in props){
        MetaDao dao=new MetaDao( props);
        auto profile= new Profile( 0, "","--",false,false,false);
        dao.remove( profile,"/a");
        BlobMeta meta= new BlobMeta();
        meta.profileId=profile.id;
        meta.owner="me";
        meta.name="a.txt";
        meta.size=3;
        meta.mediaType="text/plain";
        meta.sha="aa";
        meta.path="/a.txt";
        meta.updatedAt= Clock.currTime();
        //dao.remove(profile,"/a.txt");
        assert(!dao.create( profile,meta));
    }
}
