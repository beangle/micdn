module beangle.micdn.db;

import vibe.db.postgresql;
import vibe.core.log;
import std.datetime.systime;
import beangle.micdn.config;
import std.stdio;
class MetaDao{

    PostgresClient client;
    string schema;

    this(string[string] props){
        import std.format;
        import std.conv;
        auto url = format( "host=%s dbname=%s user=%s password=%s",props["serverName"],props["databaseName"],props["user"],props["password"]);
        auto maximumPoolSize= props.get( "maximumPoolSize","10").to!ushort;
        schema= props["schema"];
        client = new PostgresClient( url, maximumPoolSize);
    }

    void remove(Profile profile,string path){
        client.pickConnection(
        (scope conn) {
            QueryParams query;
            query.sqlCommand = "delete from "~schema~".blob_metas where profile_id=$1 and path=$2";
            import std.conv;
            query.argsVariadic( profile.id,path);
            auto r= conn.execParams( query);
            scope(exit) destroy( r);
        }
        );
    }

    public bool create(Profile profile,BlobMeta m){
        bool success=false;
        client.pickConnection(
        (scope conn) {
            QueryParams query;
            query.sqlCommand = "insert into "~schema
            ~".blob_metas(id,owner,name,size,sha,media_type,profile_id,path,updated_at) values(datetime_id(),$1,$2,$3,$4,$5,$6,$7,$8)";
            import std.conv;
            query.argsVariadic( m.owner,m.name,m.size.to!long,m.sha,m.mediaType,m.profileId,m.path,m.updatedAt);
            try{
                auto r = conn.execParams( query);
                scope(exit) destroy( r);
                success= true;
            }catch(Exception ){
                success= false;
            }
        }
        );
        return success;
    }
    public void loadProfiles(Config config){
        client.pickConnection(
        (scope conn) {
            auto r = conn.execStatement( "select name,key from "~schema ~".users");
            for (auto row = 0; row < r.length; row++){
                string name= r[row]["name"].as!PGtext;
                string key = r[row]["key"].as!PGtext;
                config.keys[name]=key;
            }
            destroy( r);
            auto r2 = conn.execStatement( "select id,path,users,named_by_sha,public_list,public_download from "~schema ~".profiles");
            for (auto row = 0; row < r2.length; row++){
                int id= r2[row]["id"].as!PGinteger;
                string path = r2[row]["path"].as!PGtext;
                string users = r2[row]["users"].as!PGtext;
                bool namedBySha = r2[row]["named_by_sha"].as!PGboolean;
                bool publicList = r2[row]["public_list"].as!PGboolean;
                bool publicDownload = r2[row]["public_download"].as!PGboolean;
                import std.array;
                string[string] profileKeys;
                if (!users.empty){
                    foreach (u;users.split( ",")){
                        if (u in config.keys){
                            profileKeys[u]=config.keys[u];
                        }else {
                            logInfo( "ignore illegal user "~ u);
                        }
                    }
                }
                config.profiles[path]=new Profile( id,path,profileKeys,namedBySha,publicList,publicDownload);
            }
            destroy( r2);
        }
        );
    }
}

unittest{
    import std.stdio;
    string[string] props;
    props["serverName"]="localhost";
    props["databaseName"]="openurp";
    props["user"]="openurp";
    props["schema"]="blob";
    props["password"]="openurp";
    MetaDao dao;
    if ("password" in props){
        dao = new MetaDao( props);
    }
    if (dao !is null){
        auto profile= new Profile( 0, "",null,false,false,false);
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
        dao.remove( profile,"/a.txt");
        assert(dao.create( profile,meta));
    }
    if (dao !is null){
        Config config = new Config( "~/tmp");
        dao.loadProfiles( config);
    }
}
