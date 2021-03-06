#!python
#cython: boundscheck=False
#cython: wraparound=False
#cython: cdivision=True

import numpy as np
cimport numpy as cnp
cimport cython

include "../../build/config.pxi"

IF HAVE_OPENMP:
    cimport openmp
ELSE:
    msg = 'OpenMP is not available with your compiler.\n'
    msg += 'Disabled OpenMP based multithreading.'
    print(msg)


from cython.parallel import prange
from libc.stdlib cimport malloc, free
from libc.math cimport sqrt, sin, cos


cdef cnp.dtype f64_dt = np.dtype(np.float64)


cdef double min_direct_flip_dist(double *a,double *b,
                                 cnp.npy_intp rows) nogil:
    r""" Minimum of direct and flip average (MDF) distance [Garyfallidis12]
    between two streamlines.

    Parameters
    ----------
    a : double pointer
        first streamline
    b : double pointer
        second streamline
    rows : number of points of the streamline
        both tracks need to have the same number of points

    Returns
    -------
    out : double
        mininum of direct and flipped average distances

    Reference
    ---------
    .. [Garyfallidis12] Garyfallidis E. et al., QuickBundles a method for
                        tractography simplification, Frontiers in Neuroscience,
                        vol 6, no 175, 2012.
    """

    cdef:
        cnp.npy_intp i=0, j=0
        double sub=0, subf=0, distf=0, dist=0, tmprow=0, tmprowf=0


    for i in range(rows):
        tmprow = 0
        tmprowf = 0
        for j in range(3):
            sub = a[i * 3 + j] - b[i * 3 + j]
            subf = a[i * 3 + j] - b[(rows - 1 - i) * 3 + j]
            tmprow += sub * sub
            tmprowf += subf * subf
        dist += sqrt(tmprow)
        distf += sqrt(tmprowf)

    dist = dist / <double>rows
    distf = distf / <double>rows

    if dist <= distf:
        return dist
    return distf


def _bundle_minimum_distance_matrix(double [:, ::1] static,
                                    double [:, ::1] moving,
                                    cnp.npy_intp static_size,
                                    cnp.npy_intp moving_size,
                                    cnp.npy_intp rows,
                                    double [:, ::1] D):
    """ MDF-based pairwise distance optimization function

    We minimize the distance between moving streamlines of the same number of
    points as they align with the static streamlines.

    Parameters
    -----------
    static: array
        Static streamlines

    moving: array
        Moving streamlines

    static_size : int
        Number of static streamlines

    moving_size : int
        Number of moving streamlines

    rows : int
        Number of points per streamline

    D : 2D array
        Distance matrix

    Returns
    -------
    cost : double
    """

    cdef:
        cnp.npy_intp i=0, j=0, mov_i=0, mov_j=0

    with nogil:

        for i in prange(static_size):

            for j in prange(moving_size):

                D[i, j] = min_direct_flip_dist(&static[i * rows, 0],
                                               &moving[j * rows, 0],
                                               rows)

    return np.asarray(D)


def _bundle_minimum_distance(double [:, ::1] stat,
                             double [:, ::1] mov,
                             cnp.npy_intp static_size,
                             cnp.npy_intp moving_size,
                             cnp.npy_intp rows):
    """ MDF-based pairwise distance optimization function

    We minimize the distance between moving streamlines of the same number of
    points as they align with the static streamlines.

    Parameters
    -----------
    static : array
        Static streamlines

    moving : array
        Moving streamlines

    static_size : int
        Number of static streamlines

    moving_size : int
        Number of moving streamlines

    rows : int
        Number of points per streamline

    Returns
    -------
    cost : double

    Notes
    -----
    The difference with ``_bundle_minimum_distance_matrix`` is that it does not
    save the full distance matrix and therefore needs much less memory.
    """

    cdef:
        cnp.npy_intp i=0, j=0
        double sum_i=0, sum_j=0, tmp=0
        double inf = np.finfo('f8').max
        double dist=0
        double * min_j
        double * min_i
        IF HAVE_OPENMP:
            openmp.omp_lock_t lock

    with nogil:

        IF HAVE_OPENMP:
            openmp.omp_init_lock(&lock)

        min_j = <double *> malloc(static_size * sizeof(double))
        min_i = <double *> malloc(moving_size * sizeof(double))

        for i in range(static_size):
            min_j[i] = inf

        for j in range(moving_size):
            min_i[j] = inf

        for i in prange(static_size):

            for j in range(moving_size):

                tmp = min_direct_flip_dist(&stat[i * rows, 0],
                                       &mov[j * rows, 0], rows)

                IF HAVE_OPENMP:
                    openmp.omp_set_lock(&lock)
                if tmp < min_j[i]:
                    min_j[i] = tmp

                if tmp < min_i[j]:
                    min_i[j] = tmp
                IF HAVE_OPENMP:
                    openmp.omp_unset_lock(&lock)

        IF HAVE_OPENMP:
            openmp.omp_destroy_lock(&lock)

        for i in range(static_size):
            sum_i += min_j[i]

        for j in range(moving_size):
            sum_j += min_i[j]

        free(min_j)
        free(min_i)

        dist = (sum_i / <double>static_size + sum_j / <double>moving_size)

        dist = 0.25 * dist * dist

    return dist


def distance_matrix_mdf(streamlines_a, streamlines_b):
    r''' Calculate distance matrix between two sets of streamlines using the
    minimum direct flipped distance.

    All streamlines need to have the same number of points

    Parameters
    ----------
    streamlines_a : sequence
       of streamlines as arrays, [(N, 3) .. (N, 3)]
    streamlines_b : sequence
       of streamlines as arrays, [(N, 3) .. (N, 3)]

    Returns
    -------
    DM : array, shape (len(streamlines_a), len(streamlines_b))
        distance matrix

    '''
    cdef:
        size_t i, j, lentA, lentB
    # preprocess tracks
    cdef:
        size_t longest_track_len = 0, track_len
        longest_track_lenA, longest_track_lenB
        cnp.ndarray[object, ndim=1] tracksA64
        cnp.ndarray[object, ndim=1] tracksB64
        cnp.ndarray[cnp.double_t, ndim=2] DM

    lentA = len(streamlines_a)
    lentB = len(streamlines_b)
    tracksA64 = np.zeros((lentA,), dtype=object)
    tracksB64 = np.zeros((lentB,), dtype=object)
    DM = np.zeros((lentA,lentB), dtype=np.double)
    if streamlines_a[0].shape[0] != streamlines_b[0].shape[0]:
        msg = 'Streamlines should have the same number of points as required'
        msg += 'by the MDF distance'
        raise ValueError(msg)
    # process tracks to predictable memory layout
    for i in range(lentA):
        tracksA64[i] = np.ascontiguousarray(streamlines_a[i], dtype=f64_dt)
    for i in range(lentB):
        tracksB64[i] = np.ascontiguousarray(streamlines_b[i], dtype=f64_dt)
    # preallocate buffer array for track distance calculations
    cdef:
        cnp.float64_t *t1_ptr, *t2_ptr, *min_buffer
    # cycle over tracks
    cdef:
        cnp.ndarray [cnp.float64_t, ndim=2] t1, t2
        size_t t1_len, t2_len
        double d[2]
    t_len = tracksA64[0].shape[0]

    for i from 0 <= i < lentA:
        t1 = tracksA64[i]
        t1_ptr = <cnp.float64_t *>t1.data
        for j from 0 <= j < lentB:
            t2 = tracksB64[j]
            t2_ptr = <cnp.float64_t *>t2.data

            DM[i, j] = min_direct_flip_dist(t1_ptr, t2_ptr,t_len)

    return DM