package database

import (
	"os"
	"path/filepath"
	"time"

	"github.com/jinzhu/gorm"
	_ "github.com/jinzhu/gorm/dialects/mysql"    // enable the mysql dialect
	_ "github.com/jinzhu/gorm/dialects/postgres" // enable the postgres dialect
	_ "github.com/jinzhu/gorm/dialects/sqlite"   // enable the sqlite3 dialect
	"github.com/rs/zerolog/log"
	"momenttally.com/server/logger"
	"momenttally.com/server/model"
)

var mkdirAll = os.MkdirAll

// New creates a gorm instance.
func New(dialect, connection string) (*gorm.DB, error) {
	createDirectoryIfSqlite(dialect, connection)

	db, err := gorm.Open(dialect, connection)
	if err != nil {
		return nil, err
	}
	db.LogMode(true)
	db.SetLogger(&logger.DatabaseLogger{})

	// We normally don't need that much connections, so we limit them. F.ex. mysql complains about
	// "too many connections".
	db.DB().SetMaxOpenConns(10)

	if dialect == "sqlite3" {
		// We use the database connection inside the handlers from the http
		// framework, therefore concurrent access occurs. Sqlite cannot handle
		// concurrent writes, so we limit sqlite to one connection.
		// see https://github.com/mattn/go-sqlite3/issues/274
		db.DB().SetMaxOpenConns(1)
		db.Exec("PRAGMA foreign_keys = ON")
	}

	log.Debug().Msg("Auto migrating schema's")
	db.AutoMigrate(model.All()...)

	// Backfill sync timestamps on rows that predate the updated_at_utc
	// columns (AutoMigrate adds them as NULL, which breaks scanning into
	// time.Time and would hide the rows from the sync delta feed). The unix
	// epoch means "predates sync": ancient, so it loses last-writer-wins to
	// any real edit.
	epoch := time.Unix(0, 0).UTC()
	for _, table := range []string{
		"time_spans", "tag_definitions", "label_value_colors",
		"label_sets", "user_preferences",
	} {
		db.Table(table).
			Where("updated_at_utc IS NULL").
			Update("updated_at_utc", epoch)
	}

	// Same idea for the quick flag on label-set members (#92): AutoMigrate
	// adds the column as NULL, and every row that predates it is a regular
	// member.
	db.Table("label_set_members").
		Where("quick IS NULL").
		Update("quick", false)

	// And for span-tag positions (#159). On sqlite, rank by rowid within
	// each span — the insertion order clients had been observing before the
	// column existed. Other dialects never returned a stable pre-column
	// order to preserve (and mysql cannot update a table its subquery
	// reads), so zero is as good as any; the next edit of a span rewrites
	// its tags with real positions.
	if dialect == "sqlite3" {
		db.Exec(`UPDATE time_span_tags SET position = (
			SELECT COUNT(*) FROM time_span_tags AS other
			WHERE other.time_span_id = time_span_tags.time_span_id
			AND other.rowid < time_span_tags.rowid)
			WHERE position IS NULL`)
	} else {
		db.Table("time_span_tags").
			Where("position IS NULL").
			Update("position", 0)
	}

	log.Debug().Msg("Database initialized")
	return db, nil
}

func createDirectoryIfSqlite(dialect string, connection string) {
	if dialect == "sqlite3" {
		if _, err := os.Stat(filepath.Dir(connection)); os.IsNotExist(err) {
			if err := mkdirAll(filepath.Dir(connection), 0777); err != nil {
				panic(err)
			}
		}
	}
}
