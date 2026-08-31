package database

import (
	"errors"
	"os"
	"testing"

	"github.com/rs/zerolog"
	"github.com/stretchr/testify/assert"
	"momenttally.com/server/logger"
	"momenttally.com/server/model"
)

func TestMain(m *testing.M) {
	logger.Init(zerolog.WarnLevel)
	os.Exit(m.Run())
}

func TestInvalidDialect(t *testing.T) {
	_, err := New("asdf", "testdb.db")
	assert.NotNil(t, err)
}

func TestCreateSqliteFolder(t *testing.T) {
	// ensure path not exists
	os.RemoveAll("somepath")

	db, err := New("sqlite3", "somepath/testdb.db")
	assert.Nil(t, err)
	assert.DirExists(t, "somepath")
	db.Close()

	assert.Nil(t, os.RemoveAll("somepath"))
}

func TestWithAlreadyExistingSqliteFolder(t *testing.T) {
	// ensure path not exists
	os.RemoveAll("somepath")
	os.MkdirAll("somepath", 0777)

	db, err := New("sqlite3", "somepath/testdb.db")
	assert.Nil(t, err)
	assert.DirExists(t, "somepath")
	db.Close()

	assert.Nil(t, os.RemoveAll("somepath"))
}

func TestBackfillSpanTagPositions(t *testing.T) {
	os.RemoveAll("backfillpath")
	defer os.RemoveAll("backfillpath")

	db, err := New("sqlite3", "backfillpath/testdb.db")
	assert.Nil(t, err)
	db.Create(&model.User{ID: 1, Name: "u", Pass: []byte{1}})
	db.Create(&model.TimeSpan{ID: 1, UserID: 1})
	db.Create(&model.TimeSpan{ID: 2, UserID: 1})
	// Rows that predate the position column (#159) hold NULL there.
	db.Exec(`INSERT INTO time_span_tags (time_span_id, key, string_value, position)
		VALUES (1, 'b', '', NULL), (1, 'a', '', NULL), (2, 'c', '', NULL)`)
	assert.Nil(t, db.Close())

	// Reopening backfills positions per span in insertion (rowid) order —
	// the order clients had been observing incidentally.
	db, err = New("sqlite3", "backfillpath/testdb.db")
	assert.Nil(t, err)
	defer db.Close()
	var tags []model.TimeSpanTag
	assert.Nil(t, db.Order("time_span_id, position").Find(&tags).Error)
	assert.Equal(t, []model.TimeSpanTag{
		{TimeSpanID: 1, Position: 0, Key: "b"},
		{TimeSpanID: 1, Position: 1, Key: "a"},
		{TimeSpanID: 2, Position: 0, Key: "c"},
	}, tags)
}

func TestPanicsOnMkdirError(t *testing.T) {
	os.RemoveAll("somepath")
	mkdirAll = func(path string, perm os.FileMode) error {
		return errors.New("ERROR")
	}
	assert.Panics(t, func() {
		New("sqlite3", "somepath/test.db")
	})
}
