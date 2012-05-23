module SSCA2_kernels

//  +==========================================================================+
//  |  Polymorphic Implementation of SSCA #2, Kernels 2-4                      |
//  |                                                                          |
//  |  Each kernel takes a graph argument which provides for each vertex       |
//  |  1.  an iterator for its set of neighbors                                |
//  |  2.  a parallel integer array of edge weights, which can be zipper       |
//  |      iterated with the set of neighbors                                  |
//  |  3.  the number of neighbors                                             |
//  |                                                                          |
//  |  These are the only requirements on the representation of the graph.     |
//  |                                                                          |
//  |  Filtering in Kernel 4 is turned on or off by a compilation time param.  |
//  +==========================================================================+

{ 
  use SSCA2_compilation_config_params, Time;

  var stopwatch : Timer;

  // ========================================================
  //                           KERNEL 2:
  // ========================================================
  // Find the edges with the largest edges.  Return a list of 
  // edges, all of which have the largest weight.
  // ========================================================
  
  proc largest_edges ( G, heavy_edge_list :domain )
    
    // edge_weights can be either an array over an associative
    // domain or over a sparse domain.  the output  heavy_edge_list
    // can either kind of domain or something else purpose-built
    // for this task.
    {
      if PRINT_TIMING_STATISTICS then stopwatch.start ();

      // ---------------------------------------------------------
      // find heaviest edge weight in a single pass over all edges
      // ---------------------------------------------------------

      proc maxweight(s) {
	var mymax = 0;
	for w in G.edge_weight[s] do
	  if w > mymax then mymax = w;
	return mymax;
      }

      const heaviest_edge_weight = max reduce [s in G.vertices] maxweight(s);

      // ---------------------------------------------
      // in a second pass over all edges, extract list 
      // of all edges  matching the heaviest weight
      // ---------------------------------------------

      forall s in G.vertices do
        forall (t, w) in ( G.Neighbors (s), G.edge_weight (s) ) do

	  if w == heaviest_edge_weight then {
	    heavy_edge_list.add ( (s,t) ); 
	  };

      if PRINT_TIMING_STATISTICS then {
	stopwatch.stop ();
	writeln ( "Elapsed time for Kernel 2: ", stopwatch.elapsed (), 
		  " seconds");
	stopwatch.clear ();
      }

      // ------------------------------------------------
      // should be able to write a user-defined "maxlocs" 
      // reduction more efficiently than this scheme
      // ------------------------------------------------

      if DEBUG_KERNEL2 then {
	writeln ();
	writeln ( "Heaviest weight      : ", heaviest_edge_weight); 
	writeln ( "Number of heavy edges:", heavy_edge_list.numIndices );
	writeln ();
	writeln ( "Edges with largest weight and other neighbors:" );
	for (s,t) in heavy_edge_list do {
	  writeln ("edge   ", (s,t));
	  for (v,w) in (G.Neighbors (s), G.edge_weight (s) ) do
	    writeln ("      ", v, " ", w);}
      }
    };
	      
  
  // ===================================================================
  //                              KERNEL 3:
  // ===================================================================
  // For each root (heavy) edge, find the subgraph (vertices and edges)
  // defined by directed paths of length no greater than max_path_length
  // in which the first edge traversed is the root edge
  // ===================================================================
  
  proc rooted_heavy_subgraphs ( G, 
                                Heavy_Edge_List     : domain,
                                Heavy_Edge_Subgraph : [],
                                in max_path_length  : int )
    
    // -------------------------------------------------------------------------
    // there is a classic space versus time tradeoff.  if the subgraphs expanded
    // by breadth first search are small, it would make sense to use a hash
    // table or an associative domain to represent the search.  If the subgraphs
    // are large, using a full length vector to represent the search is more
    // appropriate.  We expect small diameters for power law graphs, so we
    // expect large subgraphs.
    // -------------------------------------------------------------------------
  
    {
      if PRINT_TIMING_STATISTICS then stopwatch.start ();

      const vertex_domain = G.vertices;
      
      forall ( x, y ) in Heavy_Edge_List do {
	var Active_Level, Next_Level : domain ( index (vertex_domain) );
	var min_distance             : [vertex_domain] atomic int;
        forall m in min_distance do m.write(-1);
	  
	if DEBUG_KERNEL3 then 
	  writeln ( " Building heavy edge subgraph from pair:", (x,y) );
	Active_Level.add ( y );
	Next_Level.clear ();
	Heavy_Edge_Subgraph ( (x, y) ).nodes.clear ();
	Heavy_Edge_Subgraph ( (x, y) ).edges.clear ();
	min_distance ( y ).write(0);

	Heavy_Edge_Subgraph ( (x, y) ).edges.add ( (x, y) );
	Heavy_Edge_Subgraph ( (x, y) ).nodes.add ( x );
	Heavy_Edge_Subgraph ( (x, y) ).nodes.add ( y );
  
	for path_length in 1 .. max_path_length do {
	    
	  forall v in Active_Level do {

	    forall w in G.Neighbors (v) do {


              if min_distance(w).compareExchangeStrong(-1, path_length) then {
                Next_Level.add (w);
                Heavy_Edge_Subgraph ( (x, y) ).nodes.add (w);
	      }

	      if min_distance(w).read() == path_length then {
		Heavy_Edge_Subgraph ( (x, y) ).edges.add ( (v, w) );
	      }
	    }
	  }
  
	  if path_length < max_path_length then {
	    Active_Level = Next_Level;
	    Next_Level.clear ();
	  }
	}
      }

      if PRINT_TIMING_STATISTICS then {
	stopwatch.stop ();
	writeln ( "Elapsed time for Kernel 3: ", stopwatch.elapsed (), 
		  " seconds");
	stopwatch.clear ();
      }
    } // end of rooted_heavy_subgraphs


  use BlockDist;
  // Would be nice to use PriavteDist, but aliasing is not supported (yet)
  const PrivateSpace = [LocaleSpace] dmapped Block(boundingBox=[LocaleSpace]);

  // ==================================================================
  //                              KERNEL 4
  // ==================================================================
  // Calculate Betweenness Centrality for simple unweighted directed or
  // undirected graphs, using Madduri, et.al.'s modification of 
  // Brandes's 2001 algorithm
  // ==================================================================

  proc approximate_betweenness_centrality ( G, starting_vertices, 
                                            Between_Cent : [] real,
                                            out Sum_Min_Dist : real )
  
    // -----------------------------------------------------------------------
    // The betweenness centrality metric for a given node  v  is defined
    // as the double sum over s not equal to v and  t not equal to
    // either s or v of the ratio of the number of shortest paths from s to t
    // passing through v to the number of shortest paths from s to t.
    //
    // Brandes's algorithm decomposes the computation of this metric into,
    // first, separate sums for each vertex s, which can be computed
    // independently in parallel, and 
    // two, a recursive, tree-based, calculation of the path counts for 
    // any particular s.  
    // The complexity of this algorithm is O ( |V||E| ) time for an unweighted
    // graph.  The algorithm requires O ( |V| ) temporary space for each
    // process that executes instances of the outermost loop.
    // -----------------------------------------------------------------------
    {       
      const vertex_domain = G.vertices;

      // Considering using a dense 1-d array instead.  This would
      // complicate the Level_Set implementation a little, but would
      // probably be more efficient.
      type Sparse_Vertex_List = domain(index(vertex_domain));

      var Between_Cent$ : [vertex_domain] sync real = 0.0;
      var Sum_Min_Dist$ : sync real = 0.0;

      //
      // Throughout kernel 4, we use distributed arrays that are
      // private to each iteration of the outer loop.  Because set-up
      // and clean-up of such variables is very expensive, it is
      // desirable to do it at most only once per task versus once
      // per iteration, as a task executes multiple iterations of a
      // forall loop.
      //
      // To avoid this per-iteration overhead, we have implemented
      // an optimization that make certain variables private to each
      // task.  These variables are reinitialized each iteration of
      // the loop, but not reallocated, reprivatized, etc.
      //
      // Note that the Chapel group and collaborators are currently in
      // the process of bringing the idea of task private variable to
      // the language.
      //

      // Initialize task private data
      var localePrivate: [PrivateSpace] localePrivateData(vertex_domain.type);
      forall l in localePrivate do {
        l = new localePrivateData(vertex_domain);
        for t in l.temps { // this might be bad for first-touch
          t = new taskPrivateData(domain(index(vertex_domain)), vertex_domain);
          forall v in vertex_domain do
            t.children_list[v].nd = [1..G.n_Neighbors[v]];
          for loc in Locales do on loc {
              t.Active_Level[here.id] = new Level_Set (Sparse_Vertex_List);
              t.Active_Level[here.id].previous = nil;
              t.Active_Level[here.id].next = new Level_Set (Sparse_Vertex_List);;
              t.Active_Level[here.id].next.previous = t.Active_Level[here.id];
              t.Active_Level[here.id].next.next = nil;
          }
        }
      }

      // ------------------------------------------------------ 
      // Each iteration of the outer loop of Brandes's algorithm
      // computes the contribution (the "dependency" metric) for
      // one particular vertex  (s)  independently.
      // ------------------------------------------------------
  
      if PRINT_TIMING_STATISTICS then stopwatch.start ();

      forall s in starting_vertices do {

	if DEBUG_KERNEL4 then writeln ( "expanding from starting node ", s );

        // Initialize task private variables
        const lp = localePrivate[here.id];
        const tid = lp.get_tid();
        var depend => lp.get_depend(tid);
        var min_distance  => lp.get_min_distance(tid);
        var path_count$   => lp.get_path_count(tid);
        var children_list => lp.get_children_list(tid);
        forall v in vertex_domain do {
          depend[v] = 0.0;
          min_distance[v].write(-1);
          path_count$[v].writeXF(0.0);
          children_list[v].child_count.write(0);
        }
	var Lcl_Sum_Min_Dist: sync real = 0.0;

	// The structure of the algorithm depends on a breadth-first
	// traversal. Each vertex will be marked by the length of
	// the shortest path (min_distance) from s to it. The array
	// path_count$ will hold a count of the number of shortest
	// paths from s to this node.  The number of paths in moderate
	// sized tori exceeds 2**64.
  
        //
        // Used to check termination of the forward pass
        //
        // We could use a task-private reduction variable here.  This
        // is yet another concept that the Chapel group is planning to
        // implement.
        //
        var remaining: atomic bool;
        remaining.write(true);

        //
        // Each locale will have its own level sets.  A locale's level set
        // will only contain nodes that are physically allocated on that
        // particular locale.
        //
        var Active_Level => lp.get_Active_Level(tid);
        coforall loc in Locales do on loc {
          Active_Level[here.id].Members.clear();
          Active_Level[here.id].next.Members.clear();
          if vertex_domain.dist.idxToLocale(s) == here {
            // Establish the initial level sets for the breadth-first
            // traversal from s
            Active_Level[here.id].Members.add(s);
            min_distance[s].write(0);
            path_count$[s].writeXF(1);
          }
        }

	var current_distance : int = 0;
  
	while remaining.read() do {
            remaining.clear();
	    // ------------------------------------------------
	    // expand the neighbor sets for all vertices at the
	    // current distance from the starting vertex  s
	    // ------------------------------------------------
      
	    current_distance += 1;

            var barrier = new Barrier(numLocales);

            // The Chapel compiler is still a bit conservative when it
            // comes to forwarding read-only variables to remote
            // locales, so we make a const copy here to insure it is
            // forwarded to the remote locale in the following
            // coforall loop.
            const current_distance_c = current_distance;
            coforall loc in Locales do on loc {
             forall u in Active_Level[here.id].Members do {

               forall (v, w) in ( G.Neighbors (u), G.edge_weight (u) ) do
                 on vertex_domain.dist.idxToLocale(v) {
		// --------------------------------------------
		// add any unmarked neighbors to the next level
		// --------------------------------------------
  
		if  ( FILTERING &&  w % 8 != 0 ) || !FILTERING then
		  if  min_distance[v].compareExchangeStrong(-1, current_distance_c) {
                    Active_Level[here.id].next.Members.add (v);
                    if VALIDATE_BC then
                      Lcl_Sum_Min_Dist += current_distance_c;
                  }


		// ------------------------------------------------
		// only neighbors of  u  that are in the next level
		// are on shortest paths from s through v.  Some
		// task will have set  min_distance (v) by the
		// time this code is reached, whether  v  lies in
		// the previous, the current or the next level.
		// ------------------------------------------------
  
		if min_distance[v].read() == current_distance_c {
                  path_count$[v] += path_count$[u].readFF();
                  children_list(u).add_child (v);
                }

	      }
	    };

            // This barrier is needed to insure all updates to the next
            // level are completed before updating to use the next level
            barrier.notify();
            // do some work while we wait
            if Active_Level[here.id].next.next == nil {
              Active_Level[here.id].next.next = new Level_Set (Sparse_Vertex_List);
              Active_Level[here.id].next.next.previous = Active_Level[here.id].next;
              Active_Level[here.id].next.next.next = nil;
            } else {
              Active_Level[here.id].next.next.Members.clear();
            }
            barrier.wait();

            Active_Level[here.id] = Active_Level[here.id].next;
            if Active_Level[here.id].Members.numIndices:bool then
              remaining.write(true);
          }

	};  // end forward pass

	if VALIDATE_BC then
	  Sum_Min_Dist$ += Lcl_Sum_Min_Dist;

	// -------------------------------------------------------------
	// compute the dependencies recursively, traversing the vertices 
	// of the graph in non-increasing order of distance (reverse 
	// ordering from the initial traversal)
	// -------------------------------------------------------------

	var graph_diameter = current_distance - 1;

	if DEBUG_KERNEL4 then 
	  writeln ( " graph diameter from starting node ", s, 
		    "  is ", graph_diameter );

        // Use multiple barriers to simplify synchronization between
        // the barriers in each iteration of the outer for loop
        var barrier: [2..graph_diameter] Barrier;
        [2..graph_diameter] barrier.reset(numLocales);

        coforall loc in Locales do on loc {
          // back up to last level
          var curr_Level =  Active_Level[here.id].previous;
  
          for current_distance in 2 .. graph_diameter by -1 {
            curr_Level = curr_Level.previous;

            for u in curr_Level.Members do on vertex_domain.dist.idxToLocale(u) {
              depend (u) = + reduce [v in children_list(u).Row_Children[1..children_list(u).child_count.read()]]
                ( path_count$[u].readFF() / 
                  path_count$[v].readFF() )      *
                ( 1.0 + depend (v) );
              Between_Cent$ (u) += depend (u);
            }

            // This barrier is needed to insure all updates to depend are
            // complete before the next pass.
            barrier[current_distance].barrier();
          }
        }

      }; // closure of outer embarassingly parallel forall

      if PRINT_TIMING_STATISTICS then {
	stopwatch.stop ();
	var K4_time = stopwatch.elapsed ();
	stopwatch.clear ();
	writeln ( "Elapsed time for Kernel 4: ", K4_time, " seconds");

	var n0            = + reduce [v in vertex_domain] (G.n_Neighbors (v)== 0);
	var n_edges       = + reduce [v in vertex_domain] G.n_Neighbors (v);
	var N_VERTICES    = vertex_domain.numIndices;
	var TEPS          = 7.0 * N_VERTICES * (N_VERTICES - n0) / K4_time;
	var Adjusted_TEPS = n_edges * (N_VERTICES - n0) / K4_time;

	writeln ( "                     TEPS: ", TEPS );
	writeln ( " edge count adjusted TEPS: ", Adjusted_TEPS );
      }

      if VALIDATE_BC then
	Sum_Min_Dist = Sum_Min_Dist$;
      
      Between_Cent = Between_Cent$;

      forall l in localePrivate do on l {
          for i in l.r {
            var al  => l.temps[i].Active_Level;
            coforall loc in Locales do on loc {
                var level = al[here.id];
                while level != nil {
                    var l2 = level.next;
                    delete level;
                    level = l2;
                }
            }
            delete l.temps[i];
          }
          delete l;
      }

    } // end of Brandes' betweenness centrality calculation




  //
  // Addition support data structures for kernel 4
  //

  // ------------------------------------------------------------
  // The set of vertices at a particular distance from s form a
  // level set.  The class allows the full set of vertices to be
  // partitioned into a linked list of level sets.  Each instance
  // of the outer loop in kernel 4 creates such a partitioning.
  // ============================================================

  class Level_Set {
    type Sparse_Vertex_List;
    var Members  : Sparse_Vertex_List;
    var previous : Level_Set (Sparse_Vertex_List);
    var next : Level_Set (Sparse_Vertex_List);
  }

  //
  // Data structure to save Children lists between the forward
  //  and backwards passes
  //
  record child_struct {
    type vertex;
    var nd: domain(1);
    var Row_Children: [nd] vertex;
    var child_count: atomic int;

    // This function should only be called using unique vertices
    proc add_child ( new_child: vertex ) {
      var c = child_count.fetchAdd(1)+1;
      Row_Children[c] = new_child;
    }
  }

  //
  // Implementation of task-private variables for kernel 4
  //
  class taskPrivateData {
    type Sparse_Vertex_List;
    const vertex_domain;
    // It would be nice to use an atomic for the tid, but
    // chpl_taskID_t is an opaque type.  Might be able to make some
    // assumptions about it.
    var tid$           : sync chpl_taskID_t = chpl_nullTaskID;
    var min_distance   : [vertex_domain] atomic int;
    var path_count$    : [vertex_domain] sync real(64);
    var depend         : [vertex_domain] real;
    var children_list  : [vertex_domain] child_struct(index(vertex_domain));
    var Active_Level   : [PrivateSpace] Level_Set (Sparse_Vertex_List);
  };
  inline proc =(a: chpl_taskID_t, b: chpl_taskID_t) return b;
  inline proc !=(a: chpl_taskID_t, b: chpl_taskID_t) return __primitive("!=", a, b);
  class localePrivateData {
    const vertex_domain;
    const numTasks = if dataParTasksPerLocale==0 then here.numCores
      else dataParTasksPerLocale;
    var r = [0..#numTasks];
    var temps: [r] taskPrivateData(domain(index(vertex_domain)),
                                   vertex_domain.type);
    proc get_tid() {
      // This code assumes that chpl_taskID_t is an integral type
      extern proc chpl_task_getId(): chpl_taskID_t;
      var mytid = chpl_task_getId();
      var slot = (mytid:uint % (numTasks:uint)):int;
      var tid: chpl_taskID_t = temps[slot].tid$; // lock
      while ((tid != chpl_nullTaskID) && (tid != mytid)) {
        temps[slot].tid$ = tid;                  // unlock
        slot = (slot+1)%numTasks;
        tid = temps[slot].tid$;                  // lock
      }
      temps[slot].tid$ = mytid;                  // unlock
      return slot;
    }
    inline proc get_min_distance(tid=get_tid()) return temps[tid].min_distance;
    inline proc get_path_count(tid=get_tid()) return temps[tid].path_count$;
    inline proc get_depend(tid=get_tid()) return temps[tid].depend;
    inline proc get_children_list(tid=get_tid()) return temps[tid].children_list;
    inline proc get_Active_Level(tid=get_tid()) return temps[tid].Active_Level;
  }

  //
  // simple barrier implementation
  //
  record Barrier {
    var count: atomic int;
    var done: atomic bool;

    proc Barrier(n: int) {
      reset(n);
    }

    inline proc reset(n: int) {
      on this {
        count.write(n);
        done.write(false);
      }
    }

    inline proc barrier() {
      on this {
        const myc = count.fetchSub(1);
        if myc<=1 {
          if done.testAndSet() then
            halt("Too many callers to barrier()");
        } else {
          wait();
        }
      }
    }

    inline proc notify() {
      on this {
        const myc = count.fetchSub(1);
        if myc<=1 {
          if done.testAndSet() then
            halt("Too many callers to barrier_notify()");
        }
      }
    }

    inline proc wait() {
      done.waitFor(true);
    }

    inline proc try() {
      return done.read();
    }
  }

}
