module beangle.micdn.blob.db;

import vibe.db.postgresql;
import vibe.core.log;
import std.datetime.systime;
import beangle.micdn.blob.config;
import std.stdio;

class MetaDao{

  PostgresClient client;
  string schema;
  int domainId;

  this(string[string] props,Config config){
    import std.format;
    import std.conv;
    auto url = format( "host=%s dbname=%s user=%s password=%s",props["serverName"],props["databaseName"],props["user"],props["password"]);
    auto maximumPoolSize= props.get( "maximumPoolSize","7").to!ushort;
    schema= props["schema"];
    client = new PostgresClient( url, maximumPoolSize);
    loadProfiles(config);
  }

  void remove(Profile profile,string path){
    client.pickConnection(
    (scope conn) {
      QueryParams query;
      query.sqlCommand = "delete from "~schema~".blob_metas where profile_id=$1 and file_path=$2";
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
      query.sqlCommand = "insert into "~schema
      ~".blob_metas(id,owner,name,file_size,sha,media_type,profile_id,file_path,updated_at,domain_id) values(datetime_id(),$1,$2,$3,$4,$5,$6,$7,now(),$8)";
      import std.conv;
      query.argsVariadic( m.owner,m.name,m.fileSize.to!long,m.sha,m.mediaType,m.profileId,m.filePath,this.domainId);
      conn.execParams( query);
      success= true;
    }
    );
    return success;
  }

  public string getFilename(Profile profile,string path){
    string filename="";
    client.pickConnection(
    (scope conn) {
      QueryParams query;
      query.sqlCommand =  "select name from "~schema ~".blob_metas where profile_id=$1 and file_path=$2";
      query.argsVariadic( profile.id,path);
      auto r= conn.execParams( query);
      if (r.length>0){
        filename= r[0][ "name"].as!PGtext;
      }
    }
    );
    return filename;
  }

  public void loadProfiles(Config config){
    client.pickConnection(
    (scope conn) {
      QueryParams query;
      query.sqlCommand = "select  id from "~schema~".domains where hostname=$1";
      query.argsVariadic( config.hostname);
      auto r0= conn.execParams( query);
      for (auto row = 0; row < r0.length; row++){
        this.domainId=r0[row]["id"].as!PGinteger;
        break ;
      }
      if (this.domainId==0){
        throw new Exception( "cannot find domain with hostname "~ config.hostname);
      }
      import std.conv;
      auto r = conn.execStatement( "select name,key from "~schema ~".users where domain_id="~domainId.to!string);
      for (auto row = 0; row < r.length; row++){
        string name= r[row]["name"].as!PGtext;
        string key = r[row]["key"].as!PGtext;
        config.keys[name]=key;
      }
      auto r2 = conn.execStatement( "select id,base,users,named_by_sha,public_download from "~schema ~".profiles where domain_id="~this.domainId.to!string);
      for (auto row = 0; row < r2.length; row++){
        int id= r2[row]["id"].as!PGinteger;
        string base = r2[row]["base"].as!PGtext;
        string users = r2[row]["users"].as!PGtext;
        bool namedBySha = r2[row]["named_by_sha"].as!PGboolean;
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
        config.profiles[base]=new Profile( id,base,profileKeys,namedBySha,publicDownload);
      }
      logInfo( "find "~ r2.length.to!string ~" blob profiles");
    }
    );
  }
}

unittest{
  /*import dpq2.conv.to_d_types;
  toValue(Clock.currTime());*/
  import std.stdio;
  string[string] props;
  props["serverName"]="localhost";
  props["databaseName"]="platform";
  props["user"]="openurp";
  props["schema"]="blb";
  props["password"]="openurp";
  Config config = new Config( "local.openurp.net","~/tmp",true);
  MetaDao dao;
  if ("password" in props){
    dao = new MetaDao( props,config);
  }
  if (dao !is null){
    auto profile= new Profile( 1, "",null,false,false);
    dao.remove( profile,"/a");
    BlobMeta meta= new BlobMeta();
    meta.profileId=profile.id;
    meta.owner="me";
    meta.name="a.txt";
    meta.fileSize=3;
    meta.mediaType="text/plain";
    meta.sha="aa";
    meta.filePath="/a.txt";
    meta.updatedAt= Clock.currTime();
    dao.remove( profile,"/a.txt");
    assert(dao.create( profile,meta));
  }
}
