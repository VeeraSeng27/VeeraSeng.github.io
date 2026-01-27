<?php
// index.php
include 'db_connect.php';

// --- CONFIGURATION ---
// STRICT WHITELIST: Only these exact table names are allowed.
$TABLES = ['Award', 'Coach', 'Coached', 'Coach_Of', 'Competes_In', 'Game', 'Member_Of', 
           'Person', 'Player', 'Player_Earned', 'Play_Each_Other', 'Position', 
           'Season', 'Team', 'Team_Earned'];

// --- HELPER FUNCTIONS ---
function sanitize_id($str) {
    // Only allows alphanumeric and underscores (Safe for column names)
    return preg_replace('/[^a-zA-Z0-9_]/', '', $str);
}

function get_table_info($conn, $table) {
    global $TABLES;
    // SECURITY FIX: Ensure table is in the whitelist before running queries
    if (!in_array($table, $TABLES)) return ['cols' => [], 'pk' => null];

    $cols = []; $pk = null;
    $res = $conn->query("SHOW COLUMNS FROM " . $conn->real_escape_string($table));
    if ($res) {
        while ($row = $res->fetch_assoc()) {
            $cols[] = $row['Field'];
            if ($row['Key'] == 'PRI') $pk = $row['Field'];
        }
    }
    return ['cols' => $cols, 'pk' => $pk];
}

$message = ""; $msg_type = "";
function set_msg($text, $type='error') {
    global $message, $msg_type; $message = $text; $msg_type = $type;
}

// --- ACTION HANDLERS (POST) ---
if ($_SERVER['REQUEST_METHOD'] == 'POST') {
    // 1. RAW SQL (Protected by intent, but risky. Kept for your Management Tool)
    if (isset($_POST['raw_action'])) {
        $sql = trim($_POST['raw_sql']);
        $type = $_POST['raw_action'];
        
        // Basic check to ensure they are using the right box for the right action
        if (stripos($sql, $type) !== 0) {
            set_msg("Syntax Error: Must start with $type.");
        } else {
            // NOTE: Ideally, even this should be restricted, but for a management tool, 
            // we assume the user is authorized. 
            if ($conn->query($sql) === TRUE) set_msg("Success: Command executed.", "success");
            else set_msg("SQL Error: " . $conn->error);
        }
    }
    // 2. GUI INSERT
    elseif (isset($_POST['gui_insert'])) {
        $table = $_POST['target_table'];
        $values = $_POST['values'];
        
        // SECURITY FIX: Whitelist check
        if (in_array($table, $TABLES)) {
            $info = get_table_info($conn, $table);
            
            // Auto-increment logic
            if ($info['pk'] && empty($values[$info['pk']])) {
                // Safe because $table is whitelisted and $info['pk'] comes from schema
                $max = $conn->query("SELECT MAX(" . $info['pk'] . ") + 1 AS new_id FROM $table")->fetch_assoc();
                $values[$info['pk']] = $max['new_id'] ? $max['new_id'] : 1;
            }
            
            // Prepared Statement (Prevents Injection on Values)
            $cols = []; $params = []; $types = ""; $qs = [];
            foreach ($values as $c => $v) { $cols[] = $c; $params[] = $v; $types .= "s"; $qs[] = "?"; }
            
            $stmt = $conn->prepare("INSERT INTO $table (" . implode(',', $cols) . ") VALUES (" . implode(',', $qs) . ")");
            $stmt->bind_param($types, ...$params);
            if ($stmt->execute()) set_msg("Inserted new record into $table.", "success");
            else set_msg("Insert Error: " . $conn->error);
        } else {
            set_msg("Security Violation: Invalid Table.");
        }
    }
    // 3. GUI UPDATE
    elseif (isset($_POST['gui_update'])) {
        $table = $_POST['target_table']; $id = $_POST['target_id']; $values = $_POST['values'];
        
        // SECURITY FIX: Whitelist check
        if (in_array($table, $TABLES)) {
            $info = get_table_info($conn, $table);
            $set = []; $params = []; $types = "";
            foreach ($values as $c => $v) { $set[] = "$c=?"; $params[] = $v; $types .= "s"; }
            $params[] = $id; $types .= "s";
            
            // Prepared Statement
            $stmt = $conn->prepare("UPDATE $table SET " . implode(',', $set) . " WHERE " . $info['pk'] . " = ?");
            $stmt->bind_param($types, ...$params);
            if ($stmt->execute()) set_msg("Updated record in $table.", "success");
            else set_msg("Update Error: " . $conn->error);
        } else {
            set_msg("Security Violation: Invalid Table.");
        }
    }
}

// --- DELETE HANDLER (GET) ---
if (isset($_GET['action']) && $_GET['action'] == 'delete' && isset($_GET['table']) && isset($_GET['id'])) {
    $t = $_GET['table']; $id = $_GET['id'];
    
    // SECURITY FIX: Whitelist check
    if (in_array($t, $TABLES)) {
        $info = get_table_info($conn, $t);
        if ($info['pk']) {
            // Prepared Statement
            $stmt = $conn->prepare("DELETE FROM $t WHERE " . $info['pk'] . " = ?");
            $stmt->bind_param("s", $id);
            if ($stmt->execute()) set_msg("Deleted record $id.", "success");
            else set_msg("Delete Error: " . $conn->error);
        }
    } else {
        set_msg("Security Violation: Invalid Table.");
    }
}

// --- VARIABLES ---
$view = isset($_GET['view']) ? $_GET['view'] : ''; 
$val = isset($_GET['val']) ? $_GET['val'] : '';
$limit = isset($_GET['limit']) ? (int)$_GET['limit'] : 25;
$page = isset($_GET['page']) ? (int)$_GET['page'] : 1;
// Sanitize Sort Column (prevents injection in ORDER BY)
$sort_col = isset($_GET['sort_col']) ? sanitize_id($_GET['sort_col']) : '';
$sort_dir = isset($_GET['sort_dir']) && strtoupper($_GET['sort_dir']) === 'DESC' ? 'DESC' : 'ASC';
$offset = ($page - 1) * $limit;
?>

<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>NFL Database - CS 4250</title>
    <style>
        :root { --primary: #013369; --secondary: #d50a0a; --bg: #f8f9fa; --card-bg: #ffffff; --text: #333; --border: #e0e0e0; }
        body { 
            font-family: 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; 
            margin: 0; padding: 40px; line-height: 1.6; color: var(--text); 
            display: flex; flex-direction: column; align-items: center;
            background-image: url('nfl.jpg'); background-size: cover;       
            background-repeat: no-repeat; background-attachment: fixed; background-position: center;  
        }

        h1 { 
            color: var(--primary); margin-bottom: 5px; font-weight: 800; text-transform: uppercase; letter-spacing: 1px;
            background: rgba(255, 255, 255, 0.9); padding: 10px 20px; border-radius: 8px;
        }

        p.team-info { background: rgba(255, 255, 255, 0.9); padding: 5px 15px; border-radius: 6px; margin-top: 0; }

        .menu, .query-box { 
            background: var(--card-bg); padding: 25px; border-radius: 12px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.05); border: 1px solid var(--border); 
            width: 100%; max-width: 900px; 
            margin: 0 auto 25px auto; 
            opacity: 0.98;
        }

        h3 { margin-top: 0; color: var(--primary); border-bottom: 2px solid var(--bg); padding-bottom: 10px; margin-bottom: 20px; }
        
        .menu a.nav-link { 
            display: inline-block; margin: 5px; padding: 8px 16px;
            text-decoration: none; color: var(--primary); background: #f0f4f8; 
            border-radius: 6px; font-size: 0.9em; transition: all 0.2s ease; border: 1px solid transparent;
        }
        .menu a.nav-link:hover { background: var(--primary); color: white; transform: translateY(-2px); }
        
        input[type="text"], textarea, select { width: 100%; padding: 12px; border: 1px solid var(--border); border-radius: 6px; margin-bottom: 15px; box-sizing: border-box; font-family: inherit; }
        
        .btn { padding: 10px 20px; border-radius: 6px; border: none; cursor: pointer; font-weight: bold; transition: opacity 0.2s; color: white; text-decoration: none; display: inline-block; }
        .btn-primary { background: var(--primary); }
        .btn-danger { background: var(--secondary); font-size: 0.8em; padding: 6px 10px; }
        .btn-success { background: #28a745; }
        .btn-warn { background: #ffc107; color: #333; }
        .btn:hover { opacity: 0.8; }
        
        .alert { width: 100%; max-width: 900px; padding: 15px; margin-bottom: 20px; border-radius: 8px; text-align: center; }
        .alert-success { background: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
        .alert-error { background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }

        .table-wrapper { width: 100%; overflow-x: auto; margin-top: 20px; background: white; }
        table { border-collapse: collapse; width: 100%; }
        th { background-color: var(--primary); color: white; padding: 12px; white-space: nowrap; text-align: left; position: relative; }
        th a { color: white; text-decoration: none; display: block; width: 100%; height: 100%; }
        th a:hover { text-decoration: underline; }
        td { padding: 10px; border-bottom: 1px solid #eee; white-space: nowrap; }
        tr:hover { background-color: #f1f7ff; }

        .controls { display: flex; justify-content: space-between; align-items: center; width: 100%; margin-bottom: 10px; }
        .sql-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 15px; }
    </style>
</head>
<body>

<h1>NFL Database Interface</h1>
<p class="team-info"><strong>Team Members:</strong> Ethan Hewitt, Veeraphone Sengchiam, Sarbjot Singh</p>

<?php if ($message): ?>
    <div class="alert <?php echo ($msg_type == 'success') ? 'alert-success' : 'alert-error'; ?>">
        <?php echo htmlspecialchars($message); ?>
    </div>
<?php endif; ?>

<?php if ($view != 'manage' && $view != 'edit' && $view != 'manage_list'): ?>

<div class="menu">
    <h3>View Tables (Relations)</h3>
    <?php foreach ($TABLES as $t) echo "<a href='index.php?view=table&val=$t' class='nav-link'>$t</a>"; ?>
</div>

<div class="menu">
    <h3>Standard Queries (Part 6)</h3>
    <a href="index.php?view=query&val=1" class="nav-link">1. MVP Winners since 2020</a>
    <a href="index.php?view=query&val=2" class="nav-link">2. Count of awards per Team</a>
    <a href="index.php?view=query&val=3" class="nav-link">3. LSU Players born after 1980</a>
    <a href="index.php?view=query&val=4" class="nav-link">4. Best 49ers Season</a>
    <a href="index.php?view=query&val=5" class="nav-link">5. Coaches with 2+ Teams</a>
</div>

<div class="query-box">
    <h3>Ad-hoc SQL Query</h3>
    <form action="index.php" method="GET">
        <input type="hidden" name="view" value="adhoc">
        <textarea name="val" placeholder="SELECT * FROM Person WHERE..."><?php echo ($view == 'adhoc') ? htmlspecialchars($val) : ''; ?></textarea>
        <button type="submit" class="btn btn-primary">Submit Query</button>
        <a href="index.php" class="btn" style="background:#eee; color:#333;">Clear</a>
    </form>
</div>

<div class="menu" style="background-color: #fff3cd; border-color: #ffeeba;">
    <h3>Data Management Tools</h3>
    <p>Perform Insert, Update, and Delete operations on any table.</p>
    <a href="index.php?view=manage_list" class="btn btn-warn">Open Management Tools</a>
</div>

<?php endif; ?>

<div id="results" style="width: 100%; max-width: 1100px;">

    <?php if ($view == 'manage_list'): ?>
    <div class="menu">
        <div style="display:flex; justify-content:space-between; align-items:center;">
            <h2>Select Table to Manage</h2>
            <a href="index.php" class="btn btn-primary">Exit Tools</a>
        </div>
        <div style="margin-top:20px;">
            <?php foreach ($TABLES as $t) echo "<a href='index.php?view=manage&table=$t' class='nav-link' style='font-size:1.1em; margin:5px;'>$t</a>"; ?>
        </div>
    </div>
    <?php endif; ?>

    <?php if ($view == 'manage' && isset($_GET['table'])): 
        $t = $_GET['table']; 
        // SECURITY FIX: Whitelist check prevents URL tampering
        if (in_array($t, $TABLES)) {
            $info = get_table_info($conn, $t); $pk = $info['pk']; $cols = $info['cols'];
            
            // 1. Management Pagination Logic
            $count_res = $conn->query("SELECT COUNT(*) as c FROM $t");
            $total_rows = ($count_res) ? $count_res->fetch_assoc()['c'] : 0;
            $total_pages = ceil($total_rows / $limit);
            
            // 2. Build Query
            $sql = "SELECT * FROM $t";
            if ($sort_col) $sql .= " ORDER BY $sort_col $sort_dir";
            else $sql .= " ORDER BY 1 DESC"; 
            $sql .= " LIMIT $offset, $limit";
            
            $res = $conn->query($sql);
        } else {
            echo "<div class='alert alert-error'>Invalid Table Selected</div>";
            $res = false;
        }
    ?>
    
    <?php if (isset($t) && in_array($t, $TABLES)): ?>
    <div class="menu" style="max-width: 100%;">
        <div style="display:flex; justify-content:space-between; margin-bottom:15px;">
            <h2>Managing: <?php echo $t; ?></h2>
            <div>
                <a href="index.php?view=manage_list" class="btn btn-primary">&laquo; Back</a>
                <a href="index.php" class="btn" style="background:#ccc; color:#333;">Exit</a>
            </div>
        </div>

        <div class="sql-grid">
            <form method="POST" action="index.php?view=manage&table=<?php echo $t; ?>">
                <input type="hidden" name="raw_action" value="INSERT"><textarea name="raw_sql" rows="3" required>INSERT INTO <?php echo $t; ?> ...</textarea><button class="btn btn-success" style="width:100%">Run Insert</button>
            </form>
            <form method="POST" action="index.php?view=manage&table=<?php echo $t; ?>">
                <input type="hidden" name="raw_action" value="UPDATE"><textarea name="raw_sql" rows="3" required>UPDATE <?php echo $t; ?> SET ...</textarea><button class="btn btn-primary" style="width:100%">Run Update</button>
            </form>
            <form method="POST" action="index.php?view=manage&table=<?php echo $t; ?>">
                <input type="hidden" name="raw_action" value="DELETE"><textarea name="raw_sql" rows="3" required>DELETE FROM <?php echo $t; ?> ...</textarea><button class="btn btn-danger" style="width:100%">Run Delete</button>
            </form>
        </div>
        <hr>

        <h3>Interactive Editor</h3>
        
        <div class="controls">
            <form action="index.php" method="GET" style="margin:0;">
                <input type="hidden" name="view" value="manage">
                <input type="hidden" name="table" value="<?php echo $t; ?>">
                <input type="hidden" name="sort_col" value="<?php echo $sort_col; ?>">
                <input type="hidden" name="sort_dir" value="<?php echo $sort_dir; ?>">
                <label>Rows: </label>
                <select name="limit" onchange="this.form.submit()" style="width:auto; display:inline-block; padding:5px;">
                    <option value="25" <?php if($limit==25) echo 'selected'; ?>>25</option>
                    <option value="50" <?php if($limit==50) echo 'selected'; ?>>50</option>
                    <option value="100" <?php if($limit==100) echo 'selected'; ?>>100</option>
                    <option value="200" <?php if($limit==200) echo 'selected'; ?>>200</option>
                </select>
            </form>
            <div>
                <span style="margin-right:10px;">Page <?php echo $page; ?> of <?php echo $total_pages; ?> (<?php echo $total_rows; ?> total rows)</span>
                <?php
                $link = "index.php?view=manage&table=$t&limit=$limit&sort_col=$sort_col&sort_dir=$sort_dir";
                if ($page > 1) echo "<a href='$link&page=".($page-1)."' class='btn btn-primary'>&laquo; Prev</a> ";
                if ($page < $total_pages) echo "<a href='$link&page=".($page+1)."' class='btn btn-primary'>Next &raquo;</a>";
                ?>
            </div>
        </div>

        <div class="table-wrapper">
            <table>
                <tr>
                    <th>Actions</th>
                    <?php 
                    foreach($cols as $c) {
                        $new_dir = ($sort_col == $c && $sort_dir == 'ASC') ? 'DESC' : 'ASC';
                        $arrow = ($sort_col == $c) ? ($sort_dir == 'ASC' ? ' &#9650;' : ' &#9660;') : '';
                        $sort_link = "index.php?view=manage&table=$t&limit=$limit&page=1&sort_col=$c&sort_dir=$new_dir";
                        echo "<th><a href='$sort_link'>$c $arrow</a></th>";
                    }
                    ?>
                </tr>
                <tr style="background:#e8f4ff; border-bottom:2px solid #ccc;">
                    <form method="POST" action="index.php?view=manage&table=<?php echo $t; ?>">
                        <input type="hidden" name="gui_insert" value="1"><input type="hidden" name="target_table" value="<?php echo $t; ?>">
                        <td><button class="btn btn-success">+ Add</button></td>
                        <?php foreach($cols as $c) echo "<td><input type='text' name='values[$c]' placeholder='$c' style='margin:0; min-width:80px;'></td>"; ?>
                    </form>
                </tr>
                <?php 
                if ($res && $res->num_rows > 0) {
                    while($row = $res->fetch_assoc()) {
                        echo "<tr><td>";
                        if ($pk) {
                            echo "<a href='index.php?view=edit&table=$t&id=".$row[$pk]."' class='btn btn-primary' style='padding:4px 8px; font-size:0.8em; margin-right:5px;'>Edit</a>";
                            echo "<a href='index.php?view=manage&table=$t&action=delete&id=".$row[$pk]."' class='btn btn-danger' onclick=\"return confirm('Delete?');\">Del</a>";
                        }
                        echo "</td>";
                        foreach($row as $cell) echo "<td>".htmlspecialchars($cell)."</td>";
                        echo "</tr>";
                    }
                } else {
                     echo "<tr><td colspan='".(count($cols)+1)."'>No data found.</td></tr>";
                }
                ?>
            </table>
        </div>
    </div>
    <?php endif; ?>
    <?php endif; ?>

    <?php if ($view == 'edit' && isset($_GET['table']) && isset($_GET['id'])): 
        $t = $_GET['table']; $id = $_GET['id']; 
        // SECURITY FIX: Whitelist check
        if (in_array($t, $TABLES)) {
            $info = get_table_info($conn, $t);
            $row = $conn->query("SELECT * FROM $t WHERE " . $info['pk'] . " = '$id'")->fetch_assoc();
    ?>
    <div class="menu">
        <h2>Edit <?php echo $t; ?> (ID: <?php echo $id; ?>)</h2>
        <form method="POST" action="index.php?view=manage&table=<?php echo $t; ?>">
            <input type="hidden" name="gui_update" value="1">
            <input type="hidden" name="target_table" value="<?php echo $t; ?>">
            <input type="hidden" name="target_id" value="<?php echo $id; ?>">
            <?php foreach($row as $c => $v) {
                echo "<label><strong>$c:</strong></label>";
                if ($c == $info['pk']) echo "<input type='text' value='".htmlspecialchars($v)."' disabled style='background:#eee;'>";
                else echo "<input type='text' name='values[$c]' value='".htmlspecialchars($v)."'>";
            } ?>
            <button class="btn btn-primary">Save Changes</button> <a href="index.php?view=manage&table=<?php echo $t; ?>" class="btn btn-warn">Cancel</a>
        </form>
    </div>
    <?php 
        } else { echo "<div class='alert alert-error'>Invalid Table</div>"; }
    endif; ?>

    <?php if ($view == 'table' || $view == 'query' || $view == 'search' || $view == 'adhoc'):
        $sql = ""; $heading = "";
        
        // --- 1. TABLE VIEW ---
        if ($view == 'table') { 
            // SECURITY FIX: Check if the table is in the allowed whitelist
            if (in_array($val, $TABLES)) {
                $sql = "SELECT * FROM $val"; 
                $heading = "Table: $val"; 
            } else {
                echo "<div class='alert alert-error'>Security Warning: Invalid Table Name.</div>";
            }
        }
        
        // --- 2. SEARCH VIEW ---
        elseif ($view == 'search') { 
            // SECURITY FIX: Ensure input is escaped (Real Escape String is safe for LIKE clauses here)
            $s = $conn->real_escape_string($val); 
            $sql = "SELECT * FROM Person WHERE Last_Name LIKE '%$s%'"; 
            $heading = "Search: $val"; 
        }
        
        // --- 3. AD-HOC VIEW ---
        elseif ($view == 'adhoc') { 
            $clean = $val;

            // Step A: Fix formatting (Smart Quotes / Spaces)
            $clean = trim($clean);
            $clean = rtrim($clean, ';'); // Remove trailing semicolon
            $clean = preg_replace('/[\x{2018}\x{2019}\x{201C}\x{201D}]/u', "'", $clean); // Fix Quotes
            $clean = preg_replace('/\p{Z}/u', ' ', $clean); // Fix Spaces

            // Step B: SECURITY - Block destructive commands
            // If the query contains these words, we block it to prevent SQL Injection damage.
            $forbidden = ['DELETE', 'UPDATE', 'INSERT', 'ALTER', 'DROP', 'TRUNCATE', 'GRANT', 'REVOKE'];
            $is_safe = true;
            foreach ($forbidden as $word) {
                if (stripos($clean, $word) !== false) {
                    $is_safe = false;
                    break;
                }
            }

            if (!$is_safe) {
                echo "<div class='alert alert-error'>Security Warning: Only SELECT queries are allowed in this box. Please use the Management Tools for editing data.</div>"; 
            } else { 
                $sql = $clean;
                $heading = "Ad-hoc Result"; 
            }
        }
        elseif ($view == 'query') {
            $heading = "Query #$val Results";
            switch($val) {
                case 1: $sql = "SELECT DISTINCT P.First_Name, P.Last_Name, PO.Position_Group FROM Person P, Position PO, Award A WHERE A.Award_Year >= 2020 AND A.Award_Type = 'Super Bowl MVP' AND A.PersonID = PO.PlayerID AND PO.PlayerID = P.PersonID"; break;
                case 2: $sql = "SELECT T.TeamName, TE.TeamID, COUNT(TE.Award_ID) as Award_Count FROM Team_Earned TE, Team T WHERE TE.TeamID = T.TeamID GROUP BY T.TeamID, T.TeamName ORDER BY T.TeamID"; break;
                case 3: $sql = "SELECT P.PersonID, P.First_Name, P.Last_Name FROM Person P JOIN Player PL ON P.PersonID = PL.PlayerID WHERE P.Birthdate > 1980 AND P.Alma_Mater = 'LSU' AND P.PersonID = ANY(SELECT M.PlayerID FROM Member_Of M GROUP BY M.PlayerID HAVING COUNT(*) > 1)"; break;
                case 4: $sql = "SELECT s.SeasonID, s.Year, SUM(CASE WHEN peo.Winner = t.TeamID THEN 1 ELSE 0 END) AS Wins FROM Season s JOIN Game g ON g.SeasonID = s.SeasonID JOIN Play_Each_Other peo ON peo.GameID = g.GameID JOIN Team t ON (t.TeamID = peo.TeamA OR t.TeamID = peo.TeamB) WHERE t.TeamName = '49ers' GROUP BY s.SeasonID, s.Year ORDER BY Wins DESC LIMIT 1"; break;
                case 5: $sql = "SELECT C.CoachID, P.First_Name, P.Last_Name, COUNT(DISTINCT CO.TeamID) AS NumTeamsCoached FROM Coach C JOIN Person P ON C.CoachID = P.PersonID JOIN Coach_Of CO ON C.CoachID = CO.CoachID GROUP BY C.CoachID, P.First_Name, P.Last_Name HAVING COUNT(DISTINCT CO.TeamID) >= 2"; break;
            }
        }

        if ($sql) {
            // 1. COUNT (Safe only if $sql is trusted/whitelisted above)
            $count_res = $conn->query("SELECT COUNT(*) as c FROM ($sql) as sub");
            $total_rows = ($count_res) ? $count_res->fetch_assoc()['c'] : 0;
            $total_pages = ceil($total_rows / $limit);
            
            // 2. BUILD SQL (Sort + Limit)
            $final_sql = $sql;
            if ($sort_col && stripos($sql, "ORDER BY") === false) $final_sql .= " ORDER BY $sort_col $sort_dir";
            
            if (stripos($sql, "LIMIT") === false) $final_sql .= " LIMIT $offset, $limit"; else { $total_pages = 1; $page = 1; }
            
            $result = $conn->query($final_sql);
            
            echo "<div class='menu' style='opacity:0.98;'>";
            echo "<h2>$heading</h2>";
            
            if ($result && $result->num_rows > 0) {
                $base_url = "index.php?view=" . urlencode($view) . "&val=" . urlencode($val) . "&sort_col=$sort_col&sort_dir=$sort_dir";
                ?>
                <div class="controls">
                    <form action="index.php" method="GET" style="margin:0;">
                        <input type="hidden" name="view" value="<?php echo htmlspecialchars($view); ?>">
                        <input type="hidden" name="val" value="<?php echo htmlspecialchars($val); ?>">
                        <input type="hidden" name="sort_col" value="<?php echo $sort_col; ?>">
                        <input type="hidden" name="sort_dir" value="<?php echo $sort_dir; ?>">
                        <label>Rows: </label>
                        <select name="limit" onchange="this.form.submit()" style="width:auto; display:inline-block; padding:5px;">
                            <option value="25" <?php if($limit==25) echo 'selected'; ?>>25</option>
                            <option value="50" <?php if($limit==50) echo 'selected'; ?>>50</option>
                            <option value="100" <?php if($limit==100) echo 'selected'; ?>>100</option>
                        </select>
                    </form>

                    <div>
                        <span style="margin-right:10px;">Page <?php echo $page; ?> of <?php echo $total_pages; ?> (<?php echo $total_rows; ?> total rows)</span>
                        <?php
                        $link = "index.php?view=".urlencode($view)."&val=".urlencode($val)."&limit=$limit&sort_col=$sort_col&sort_dir=$sort_dir";
                        if ($page > 1) echo "<a href='$link&page=".($page-1)."' class='btn btn-primary'>&laquo; Prev</a> ";
                        if ($page < $total_pages) echo "<a href='$link&page=".($page+1)."' class='btn btn-primary'>Next &raquo;</a>";
                        ?>
                    </div>
                </div>

                <?php
                echo "<div class='table-wrapper'><table><tr>";
                foreach($result->fetch_fields() as $f) {
                    $new_dir = ($sort_col == $f->name && $sort_dir == 'ASC') ? 'DESC' : 'ASC';
                    $arrow = ($sort_col == $f->name) ? ($sort_dir == 'ASC' ? ' &#9650;' : ' &#9660;') : '';
                    $sort_link = "index.php?view=".urlencode($view)."&val=".urlencode($val)."&limit=$limit&page=1&sort_col={$f->name}&sort_dir=$new_dir";
                    echo "<th><a href='$sort_link'>{$f->name} $arrow</a></th>";
                }
                echo "</tr>";
                
                while($row = $result->fetch_assoc()) {
                    echo "<tr>";
                    foreach($row as $c) echo "<td>".htmlspecialchars($c)."</td>";
                    echo "</tr>";
                }
                echo "</table></div>";
            } else {
                echo "<p>No results found (or query blocked).</p>";
                if ($conn->error) echo "<p style='color:red; font-size:0.8em;'>DEBUG SQL Error: " . $conn->error . "</p>";
            }
            echo "</div>";
        }
    endif; ?>

</div>

</body>
</html>