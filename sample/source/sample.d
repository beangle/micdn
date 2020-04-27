import std.stdio;

void main(string[] args)
{

    //writeln(args[0].sizeof); //16
    //writeln(args[0][0..1]);//

    //writeln(foo((args[0][0..2]).ptr));
    auto a = ["2","23"];
    auto b=a;
    int dd=45;
    writeln(a.ptr == b.ptr);
    import std.datetime.systime;
    auto st = SysTime.fromISOString("20200427T143000");
    SysTime today = Clock.currTime();
    import core.time;
    writeln("today:" ~today.toISOString);
    writeln("st:" ~st.toISOString);
    auto duration = abs(today - st);
    writeln(duration);
    writeln(duration > dur!"minutes"(15));
}

int foo(const(char)* ptr){
    int i=0;
    int max=40;
    while(*ptr >0 && i <40){
        write(*ptr);
        i++;
        ptr ++;
    }
    return i;
}
