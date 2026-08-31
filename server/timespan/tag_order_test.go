// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Steven Fitzpatrick

package timespan

import (
	"testing"

	"github.com/stretchr/testify/require"
	"momenttally.com/server/generated/gqlmodel"
	"momenttally.com/server/model"
	"momenttally.com/server/test"
	"momenttally.com/server/test/fake"
)

// Label order is part of the sync contract (#159): tags carry a position
// written from the input index, and every read orders by it.

func labelOrderUser(t *testing.T, db *test.Database) *ResolverForTimeSpan {
	user := db.User(5)
	for _, key := range []string{"proj", "area", "mood"} {
		user.NewTagDefinition(key)
	}
	return &ResolverForTimeSpan{DB: db.DB}
}

func labels(keys ...string) []*gqlmodel.InputLabel {
	result := make([]*gqlmodel.InputLabel, 0, len(keys))
	for _, key := range keys {
		result = append(result, &gqlmodel.InputLabel{Key: key, Value: "v"})
	}
	return result
}

func labelKeys(span *gqlmodel.TimeSpan) []string {
	keys := []string{}
	for _, label := range span.Labels {
		keys = append(keys, label.Key)
	}
	return keys
}

func Test_TagOrder_createWritesPositionsFromInputIndex(t *testing.T) {
	db := test.InMemoryDB(t)
	defer db.Close()
	resolver := labelOrderUser(t, db)

	created, err := resolver.CreateTimeSpan(fake.User(5), test.ModelTime("2020-01-01T09:00:00Z"), nil,
		labels("mood", "proj", "area"), "")
	require.Nil(t, err)
	require.Equal(t, []string{"mood", "proj", "area"}, labelKeys(created))

	var tags []model.TimeSpanTag
	require.Nil(t, db.Where("time_span_id = ?", created.ID).Order("key").Find(&tags).Error)
	positions := map[string]int{}
	for _, tag := range tags {
		positions[tag.Key] = tag.Position
	}
	require.Equal(t, map[string]int{"mood": 0, "proj": 1, "area": 2}, positions)
}

func Test_TagOrder_updateReorderPersists(t *testing.T) {
	db := test.InMemoryDB(t)
	defer db.Close()
	resolver := labelOrderUser(t, db)

	clockAt(t, "2020-01-01T10:00:00Z")
	created, err := resolver.CreateTimeSpan(fake.User(5), test.ModelTime("2020-01-01T09:00:00Z"), nil,
		labels("proj", "area", "mood"), "")
	require.Nil(t, err)

	clockAt(t, "2020-01-01T11:00:00Z")
	updated, err := resolver.UpdateTimeSpan(fake.User(5), created.ID, test.ModelTime("2020-01-01T09:00:00Z"), nil,
		labels("mood", "area", "proj"), nil, "")
	require.Nil(t, err)
	require.Equal(t, []string{"mood", "area", "proj"}, labelKeys(updated))

	// The reorder reaches the delta feed other devices pull.
	changes := changesSince(t, resolver, 5, "2020-01-01T10:00:00Z", created.ID, nil)
	require.Equal(t, []int{created.ID}, spanIDs(changes))
	require.Equal(t, []string{"mood", "area", "proj"}, labelKeys(changes.TimeSpans[0]))
}

// The reads must follow position, not storage order — sqlite returning
// insertion order is incidental (#159). Simulate a span whose rows are
// stored in the reverse of their positions, as after a row rewrite.
func Test_TagOrder_readsFollowPositionNotStorageOrder(t *testing.T) {
	db := test.InMemoryDB(t)
	defer db.Close()
	resolver := labelOrderUser(t, db)

	clockAt(t, "2020-01-01T10:00:00Z")
	created, err := resolver.CreateTimeSpan(fake.User(5), test.ModelTime("2020-01-01T09:00:00Z"), nil, nil, "")
	require.Nil(t, err)
	for i, key := range []string{"mood", "area", "proj"} {
		require.Nil(t, db.Create(&model.TimeSpanTag{
			TimeSpanID:  created.ID,
			Position:    2 - i,
			Key:         key,
			StringValue: "v",
		}).Error)
	}
	wantKeys := []string{"proj", "area", "mood"}

	changes := changesSince(t, resolver, 5, "1970-01-01T00:00:00Z", 0, nil)
	require.Equal(t, wantKeys, labelKeys(changes.TimeSpans[0]))

	timers, err := resolver.Timers(fake.User(5))
	require.Nil(t, err)
	require.Equal(t, wantKeys, labelKeys(timers[0]))

	stopped, err := resolver.StopTimeSpan(fake.User(5), created.ID, test.ModelTime("2020-01-01T09:30:00Z"))
	require.Nil(t, err)
	require.Equal(t, wantKeys, labelKeys(stopped))

	paged, err := resolver.TimeSpans(fake.User(5), nil, nil, nil)
	require.Nil(t, err)
	require.Equal(t, wantKeys, labelKeys(paged.TimeSpans[0]))
}
