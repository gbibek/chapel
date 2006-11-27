class trio {
  var x1;
  var x2;
  var x3;

  def sum()
    return x1 + x2 + x3;
}

def trio.write(f : file) {
  f.write("(", x1, " & ", x2, " & ", x3, ")");
}

var t1 = trio(1, 2, 3);
var t2 = trio(1.0, 2.0, 3.0);

writeln(t1);
writeln(t1.sum());
writeln(t2);
writeln(t2.sum());
